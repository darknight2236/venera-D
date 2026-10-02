import 'dart:convert';
import 'dart:typed_data';

import 'objects.dart';

class _XrefEntry {
  /// 0 = free, 1 = uncompressed (field2 = byte offset, field3 = generation),
  /// 2 = compressed (field2 = object stream number, field3 = index in it).
  final int type;
  final int field2;
  final int field3;
  const _XrefEntry(this.type, this.field2, this.field3);
}

/// Random-access view of a PDF file: xref resolution, object fetching with
/// caching, and page-tree traversal.
///
/// Parsing happens over an in-memory buffer; comic PDFs are read once at
/// import time so this is acceptable (see spec §10 limitations).
class PdfDocument {
  PdfDocument(this.bytes);

  final Uint8List bytes;

  final Map<int, _XrefEntry> _xref = {};
  final Map<int, PdfObject?> _objectCache = {};

  late PdfDictionary trailer;

  /// Set up by open() in Task 8 when the document is encrypted.
  Object? security;

  /// [passwordProvider] / [fileName] are accepted from the start so the
  /// signature never changes; Task 8 wires them into decryption.
  Future<void> open({
    PdfPasswordProvider? passwordProvider,
    String fileName = '',
  }) async {
    var offset = _findStartXref();
    PdfDictionary? firstTrailer;
    var guard = 0;
    while (offset > 0 && guard++ < 64) {
      // Offsets come from attacker-controlled integers whose intValue
      // saturates at int64-max; validate before touching the buffer.
      if (offset >= bytes.length) {
        throw PdfSyntaxException('xref offset $offset past end of file');
      }
      final section = _parseXrefAt(offset);
      firstTrailer ??= section.trailer;
      offset = section.prev;
    }
    if (firstTrailer == null) {
      throw const PdfSyntaxException('No xref section found');
    }
    trailer = firstTrailer;
  }

  int _findStartXref() {
    final from = bytes.length - 1024 < 0 ? 0 : bytes.length - 1024;
    for (var i = bytes.length - 9; i >= from; i--) {
      if (bytes[i] == 0x73 &&
          latin1.decode(bytes.sublist(i, i + 9)) == 'startxref') {
        final p = PdfParser(bytes, i + 9);
        p.skipWhitespaceAndComments();
        final n = p.parseObject();
        if (n is PdfNumber) return n.intValue;
      }
    }
    throw const PdfSyntaxException('startxref not found');
  }

  ({PdfDictionary trailer, int prev}) _parseXrefAt(int offset) {
    final p = PdfParser(bytes, offset);
    p.skipWhitespaceAndComments();
    if (p.matchKeyword('xref')) {
      return _parseClassicXref(p);
    }
    // Otherwise this offset must hold an xref stream object: "N G obj <<...>>".
    p.pos = offset;
    _skipObjectHeader(p);
    final obj = p.parseObject();
    if (obj is! PdfStream) {
      throw PdfSyntaxException('No xref at offset $offset');
    }
    final type = obj.dict['Type'];
    if (type is! PdfName || type.name != 'XRef') {
      throw PdfSyntaxException('No xref at offset $offset');
    }
    _readXrefStream(obj); // Task 4
    return (trailer: obj.dict, prev: _prevOf(obj.dict));
  }

  ({PdfDictionary trailer, int prev}) _parseClassicXref(PdfParser p) {
    while (true) {
      p.skipWhitespaceAndComments();
      if (p.matchKeyword('trailer')) break;
      final firstObj = _subsectionInt(p, 'first object number');
      final count = _subsectionInt(p, 'entry count');
      // An entry cannot physically fit in fewer than five bytes (three
      // one-char tokens plus two separators), so a larger count means a
      // corrupt header; this also caps hostile counts and keeps
      // firstObj + i from overflowing.
      final remaining = bytes.length - p.pos;
      if (firstObj < 0 ||
          count < 0 ||
          count > remaining ~/ 5 ||
          firstObj + count < firstObj) {
        throw PdfSyntaxException(
            'Corrupt xref subsection $firstObj $count ($remaining bytes left)');
      }
      for (var i = 0; i < count; i++) {
        // Entries are nominally 20 bytes but producers vary the EOL; reading
        // three whitespace-delimited tokens per entry tolerates all variants.
        final offText = p.readToken();
        final genText = p.readToken();
        final typeText = p.readToken();
        final field2 = int.tryParse(offText);
        final field3 = int.tryParse(genText);
        if (field2 == null || field3 == null) {
          throw PdfSyntaxException(
              'Malformed xref entry in subsection $firstObj $count');
        }
        final objNum = firstObj + i;
        if (_xref.containsKey(objNum)) continue; // newest section wins
        // Free entries are recorded too, so a deletion in a newer section
        // wins over an older 'n' entry further down the /Prev chain.
        _xref[objNum] = _XrefEntry(typeText == 'n' ? 1 : 0, field2, field3);
      }
    }
    final trailerObj = p.parseObject();
    if (trailerObj is! PdfDictionary) {
      throw const PdfSyntaxException('Malformed trailer');
    }
    return (trailer: trailerObj, prev: _prevOf(trailerObj));
  }

  int _subsectionInt(PdfParser p, String what) {
    final n = p.parseObject();
    if (n is! PdfNumber) {
      throw PdfSyntaxException('xref subsection header: $what is not a number');
    }
    return n.intValue;
  }

  /// A /Prev of the wrong type ends the chain instead of throwing a
  /// TypeError at a cast.
  static int _prevOf(PdfDictionary dict) {
    final prev = dict['Prev'];
    return prev is PdfNumber ? prev.intValue : 0;
  }

  /// Consumes the `N G obj` header. matchKeyword does not skip leading
  /// whitespace, and number parsing restores pos before the whitespace it
  /// scanned, so an explicit skip is required before 'obj'.
  void _skipObjectHeader(PdfParser p) {
    p.skipWhitespaceAndComments();
    p.parseObject(); // object number
    p.parseObject(); // generation
    p.skipWhitespaceAndComments();
    p.matchKeyword('obj');
  }

  /// Populated in Task 4; the classic-only parser must still compile.
  void _readXrefStream(PdfStream stream) {
    throw const PdfSyntaxException('Cross-reference streams not supported yet');
  }

  /// Fetches an object by number (with caching). Null when free/unknown.
  PdfObject? fetch(int objNum) {
    if (_objectCache.containsKey(objNum)) return _objectCache[objNum];
    final entry = _xref[objNum];
    PdfObject? obj;
    if (entry != null && entry.type == 1) {
      final offset = entry.field2;
      if (offset < 0 || offset >= bytes.length) {
        throw PdfSyntaxException(
            'Object $objNum: xref offset $offset outside the file');
      }
      final p = PdfParser(bytes, offset);
      _skipObjectHeader(p);
      obj = p.parseObject();
      if (obj is PdfStream) {
        obj.objNum = objNum;
        obj.objGen = entry.field3;
      }
    }
    _objectCache[objNum] = obj;
    return obj;
  }

  PdfObject? resolve(PdfObject? obj, [int depth = 0]) {
    if (obj is PdfRef) {
      if (depth > 32) {
        throw const PdfSyntaxException('Indirect reference cycle');
      }
      return resolve(fetch(obj.number), depth + 1);
    }
    return obj;
  }

  PdfDictionary resolveDict(PdfObject? obj) {
    final r = resolve(obj);
    if (r is! PdfDictionary) {
      throw const PdfSyntaxException('Expected a dictionary');
    }
    return r;
  }

  /// Raw stream bytes honoring an indirect /Length, and (from Task 8)
  /// transport decryption.
  Uint8List streamData(PdfStream stream) {
    final len = resolve(stream.dict['Length']);
    var raw = stream.raw;
    if (len is PdfNumber && len.intValue >= 0 && len.intValue <= raw.length) {
      raw = Uint8List.sublistView(raw, 0, len.intValue);
    }
    return raw;
  }
}
