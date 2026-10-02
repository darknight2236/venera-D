import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';

import 'document.dart';
import 'objects.dart';

/// The 32-byte padding string from ISO 32000 (Algorithm 2, step a).
final Uint8List kPdfPasswordPadding = Uint8List.fromList(const [
  0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, //
  0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08, //
  0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, //
  0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A, //
]);

/// Hand-rolled RC4 (ARC4): pointycastle ships no RC4, and the cipher is small
/// enough to keep the dependency surface unchanged.
Uint8List rc4(Uint8List key, Uint8List data) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xFF;
    final t = s[i];
    s[i] = s[j];
    s[j] = t;
  }
  final out = Uint8List(data.length);
  var a = 0, b = 0;
  for (var k = 0; k < data.length; k++) {
    a = (a + 1) & 0xFF;
    b = (b + s[a]) & 0xFF;
    final t = s[a];
    s[a] = s[b];
    s[b] = t;
    out[k] = data[k] ^ s[(s[a] + s[b]) & 0xFF];
  }
  return out;
}

Uint8List aesCbcEncryptNoPad(Uint8List key, Uint8List iv, Uint8List data) {
  final c = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off + 16 <= data.length; off += 16) {
    c.processBlock(data, off, out, off);
  }
  return out;
}

Uint8List aesCbcDecryptNoPad(Uint8List key, Uint8List iv, Uint8List data) {
  final n = data.length - data.length % 16;
  final c = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(n);
  for (var off = 0; off + 16 <= n; off += 16) {
    c.processBlock(data, off, out, off);
  }
  return out;
}

Uint8List aesEcbDecryptNoPad(Uint8List key, Uint8List data) {
  final n = data.length - data.length % 16;
  final c = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));
  final out = Uint8List(n);
  for (var off = 0; off + 16 <= n; off += 16) {
    c.processBlock(data, off, out, off);
  }
  return out;
}

/// Removes PKCS#7 padding, tolerating producers that omit it (returns [data]
/// unchanged when the trailing byte is not a valid pad length).
Uint8List stripPkcs7(Uint8List data) {
  if (data.isEmpty) return data;
  final pad = data.last;
  if (pad < 1 || pad > 16 || pad > data.length) return data;
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) return data;
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

bool _eqBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _bytesOf(PdfObject? o) => o is PdfString ? o.bytes : Uint8List(0);

/// Pads or truncates a password to exactly 32 bytes (Algorithm 2, step a).
Uint8List _padPassword(List<int> pw) {
  final out = Uint8List(32);
  final n = pw.length < 32 ? pw.length : 32;
  out.setRange(0, n, pw);
  if (n < 32) out.setRange(n, 32, kPdfPasswordPadding.sublist(0, 32 - n));
  return out;
}

enum PdfCipher { rc4, aes128, aes256 }

/// Holds the derived file key for one document and decrypts its streams.
class PdfSecurityHandler {
  PdfSecurityHandler({
    required this.fileKey,
    required this.cipher,
    required this.encryptMetadata,
  });

  final Uint8List fileKey;
  final PdfCipher cipher;
  final bool encryptMetadata;

  /// Algorithm 1: per-object key for RC4 / AES-128 (R2-R4).
  Uint8List _objectKey(int objNum, int objGen, bool aes) {
    final input = BytesBuilder()
      ..add(fileKey)
      ..add([
        objNum & 0xFF,
        (objNum >> 8) & 0xFF,
        (objNum >> 16) & 0xFF,
        objGen & 0xFF,
        (objGen >> 8) & 0xFF,
      ]);
    if (aes) input.add(const [0x73, 0x41, 0x6C, 0x54]); // "sAlT"
    final digest = md5.convert(input.toBytes()).bytes;
    final len = (fileKey.length + 5) > 16 ? 16 : (fileKey.length + 5);
    return Uint8List.fromList(digest.sublist(0, len));
  }

  /// Decrypts one stream's raw bytes. [objNum] / [objGen] drive the per-object
  /// key for R2-R4; R5/R6 use the 32-byte file key directly.
  Uint8List decryptStream(Uint8List data, int objNum, int objGen) {
    switch (cipher) {
      case PdfCipher.aes256:
        if (data.length < 32) return data;
        return stripPkcs7(aesCbcDecryptNoPad(
          fileKey,
          Uint8List.sublistView(data, 0, 16),
          Uint8List.sublistView(data, 16),
        ));
      case PdfCipher.aes128:
        if (data.length < 32) return data;
        return stripPkcs7(aesCbcDecryptNoPad(
          _objectKey(objNum, objGen, true),
          Uint8List.sublistView(data, 0, 16),
          Uint8List.sublistView(data, 16),
        ));
      case PdfCipher.rc4:
        return rc4(_objectKey(objNum, objGen, false), data);
    }
  }
}

/// Reads `/Encrypt` from [doc]'s trailer and, when present, derives the file
/// key and assigns [PdfDocument.security]. Tries the empty password first
/// (owner-only encryption), then loops over [passwordProvider].
///
/// Throws [PdfCancelledException] when the provider returns null, or
/// [PdfEncryptedException] when the document is encrypted and no provider was
/// supplied. Must run after the xref/trailer are parsed but before any
/// encrypted object is consumed.
Future<void> setupSecurity(
  PdfDocument doc, {
  PdfPasswordProvider? passwordProvider,
  String fileName = '',
}) async {
  final encryptRef = doc.trailer['Encrypt'];
  if (encryptRef == null) return;
  final encrypt = doc.resolveDict(encryptRef);
  final id0 = _firstId(doc);
  final v = _intOf(doc, encrypt['V']) ?? 0;
  final r = _intOf(doc, encrypt['R']) ?? 0;

  var password = '';
  while (true) {
    final handler = _buildHandler(encrypt, v, r, id0, password);
    if (handler != null) {
      doc.security = handler;
      return;
    }
    if (passwordProvider == null) {
      throw const PdfEncryptedException();
    }
    final next = await passwordProvider(fileName);
    if (next == null) {
      throw const PdfCancelledException();
    }
    password = next;
  }
}

int? _intOf(PdfDocument doc, PdfObject? obj) {
  final r = doc.resolve(obj);
  return r is PdfNumber ? r.intValue : null;
}

Uint8List _firstId(PdfDocument doc) {
  final id = doc.resolve(doc.trailer['ID']);
  if (id is PdfArray && id.items.isNotEmpty) {
    final first = doc.resolve(id.items.first);
    if (first is PdfString) return first.bytes;
  }
  return Uint8List(0);
}

/// Derives the file key for [password] and validates it against `/U`.
/// Returns null when the password is wrong.
PdfSecurityHandler? _buildHandler(
  PdfDictionary encrypt,
  int v,
  int r,
  Uint8List id0,
  String password,
) {
  final encryptMetadata =
      (encrypt['EncryptMetadata'] as PdfBool?)?.value ?? true;

  if (v == 5 || r >= 5) {
    // AES-256 (R5/R6) is implemented in Task 9.
    throw const PdfExtractException(
        'AES-256 encrypted PDF support added in Task 9');
  }

  final o = _bytesOf(encrypt['O']);
  final u = _bytesOf(encrypt['U']);
  final p = (encrypt['P'] as PdfNumber?)?.intValue ?? 0;
  final keyBits =
      r >= 3 ? ((encrypt['Length'] as PdfNumber?)?.intValue ?? 128) : 40;
  final keyLen = keyBits ~/ 8;
  if (keyLen < 5 || keyLen > 16) {
    throw PdfExtractException('Implausible encryption key length $keyLen');
  }

  // Algorithm 2: file encryption key.
  final hashInput = BytesBuilder()
    ..add(_padPassword(latin1.encode(password)))
    ..add(o)
    ..add([p & 0xFF, (p >> 8) & 0xFF, (p >> 16) & 0xFF, (p >> 24) & 0xFF])
    ..add(id0);
  if (r >= 4 && !encryptMetadata) {
    hashInput.add([0xFF, 0xFF, 0xFF, 0xFF]);
  }
  var key = Uint8List.fromList(md5.convert(hashInput.toBytes()).bytes);
  if (r >= 3) {
    for (var i = 0; i < 50; i++) {
      key = Uint8List.fromList(md5.convert(key.sublist(0, keyLen)).bytes);
    }
  }
  key = Uint8List.fromList(key.sublist(0, keyLen));

  final ok = r == 2 ? _checkU2(key, u) : _checkU3(key, id0, u);
  if (!ok) return null;

  return PdfSecurityHandler(
    fileKey: key,
    cipher: _cipherFor(encrypt, v),
    encryptMetadata: encryptMetadata,
  );
}

/// Algorithm 4 (R2): U == RC4(key, padding32).
bool _checkU2(Uint8List key, Uint8List u) {
  if (u.isEmpty) return false;
  final expected = rc4(key, kPdfPasswordPadding);
  final n = u.length < 32 ? u.length : 32;
  return _eqBytes(expected.sublist(0, n), u.sublist(0, n));
}

/// Algorithm 5 (R3/R4): MD5(padding32 ‖ ID[0]) then 20 RC4 rounds; compare
/// the first 16 bytes with U[0:16].
bool _checkU3(Uint8List key, Uint8List id0, Uint8List u) {
  if (u.length < 16) return false;
  final hashed = md5.convert((BytesBuilder()
        ..add(kPdfPasswordPadding)
        ..add(id0))
      .toBytes())
      .bytes;
  var data = rc4(key, Uint8List.fromList(hashed));
  for (var i = 1; i <= 19; i++) {
    final xk = Uint8List.fromList(key.map((b) => b ^ i).toList());
    data = rc4(xk, data);
  }
  return _eqBytes(data, u.sublist(0, 16));
}

/// Picks the stream cipher from the V4 crypt-filter dictionary (/StmF → /CFM).
PdfCipher _cipherFor(PdfDictionary encrypt, int v) {
  if (v != 4) return PdfCipher.rc4; // V1/V2 are always RC4.
  final stmF = (encrypt['StmF'] as PdfName?)?.name ?? 'StdCF';
  final cf = encrypt['CF'];
  if (cf is PdfDictionary) {
    final entry = cf.map[stmF];
    if (entry is PdfDictionary) {
      final method = (entry['CFM'] as PdfName?)?.name ?? 'V2';
      return method == 'AESV2' ? PdfCipher.aes128 : PdfCipher.rc4;
    }
  }
  return PdfCipher.rc4;
}
