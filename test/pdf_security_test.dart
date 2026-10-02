import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/document.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/pdf/security.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/pdf/$name').readAsBytesSync();

void main() {
  group('rc4 primitive', () {
    test('matches the reference vector Key/Plaintext', () {
      final out = rc4(
        Uint8List.fromList(utf8.encode('Key')),
        Uint8List.fromList(utf8.encode('Plaintext')),
      );
      expect(out, [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3]);
    });

    test('is symmetric', () {
      final key = Uint8List.fromList([1, 2, 3]);
      final data = Uint8List.fromList([9, 8, 7, 6, 5]);
      expect(rc4(key, rc4(key, data)), data);
    });
  });

  group('standard security handler R2-R4', () {
    test('opens an RC4-128 encrypted PDF with the user password', () async {
      final images = await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
      expect(images.first.bytes[0], 0xFF);
    });

    test('opens an AES-128 (V4) encrypted PDF with the user password',
        () async {
      final images = await extractPdfImages(
        _fixture('enc_aes128.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
    });

    test('owner-only PDF opens with the empty password, no provider needed',
        () async {
      final images = await extractPdfImages(_fixture('owner_only.pdf')).toList();
      expect(images.length, 2);
    });

    test('encrypted PDF without a provider throws PdfEncryptedException',
        () async {
      await expectLater(
        extractPdfImages(_fixture('enc_rc4_128.pdf')).toList(),
        throwsA(isA<PdfEncryptedException>()),
      );
    });

    test('cancelling the prompt throws PdfCancelledException', () async {
      await expectLater(
        extractPdfImages(
          _fixture('enc_rc4_128.pdf'),
          passwordProvider: (_) async => null,
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
    });

    test('a wrong password is not accepted silently', () async {
      // The parser tries the empty password first without asking, then calls
      // the provider once for the wrong guess and once more when it cancels.
      var calls = 0;
      await expectLater(
        extractPdfImages(
          _fixture('enc_aes128.pdf'),
          passwordProvider: (_) async {
            calls++;
            return calls == 1 ? 'totally-wrong' : null;
          },
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
      expect(calls, 2);
    });

    test('an unencrypted PDF gets no security handler', () async {
      final doc = PdfDocument(_fixture('plain_jpeg.pdf'));
      await doc.open();
      expect(doc.security, isNull);
    });

    test('an encrypted PDF installs a handler with a 16-byte file key',
        () async {
      final doc = PdfDocument(_fixture('enc_rc4_128.pdf'));
      await doc.open(passwordProvider: (_) async => 'user123');
      expect(doc.security, isNotNull);
      expect(doc.security!.fileKey.length, 16);
    });
  });

  group('standard security handler R5/R6 (AES-256)', () {
    test('opens an AES-256 (R6) encrypted PDF with the user password',
        () async {
      final images = await extractPdfImages(
        _fixture('enc_aes256_r6.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
      // A wrong key would yield bytes that are not a JPEG SOI marker.
      expect(images.first.bytes[0], 0xFF);
      expect(images.first.bytes[1], 0xD8);
    });

    test('installs a 32-byte file key and the AES-256 cipher', () async {
      final doc = PdfDocument(_fixture('enc_aes256_r6.pdf'));
      await doc.open(passwordProvider: (_) async => 'user123');
      expect(doc.security!.fileKey.length, 32);
      expect(doc.security!.cipher, PdfCipher.aes256);
    });

    test('a wrong password for an R6 PDF is rejected', () async {
      var calls = 0;
      await expectLater(
        extractPdfImages(
          _fixture('enc_aes256_r6.pdf'),
          passwordProvider: (_) async {
            calls++;
            return calls == 1 ? 'nope' : null;
          },
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
      expect(calls, 2);
    });
  });
}
