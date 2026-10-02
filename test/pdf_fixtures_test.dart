import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/images.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/pdf/$name').readAsBytesSync();

void main() {
  const fixtures = [
    'plain_jpeg.pdf',
    'enc_rc4_128.pdf',
    'enc_aes128.pdf',
    'enc_aes256_r6.pdf',
    'owner_only.pdf',
  ];

  group('PDF fixtures', () {
    for (final name in fixtures) {
      test('$name exists and starts with %PDF-', () {
        final bytes = _fixture(name);
        expect(bytes.length, greaterThan(64));
        expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      });
    }

    test('plain_jpeg.pdf yields two JPEG images', () async {
      final images =
          await extractPdfImages(_fixture('plain_jpeg.pdf')).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
      // JPEG SOI marker 0xFFD8.
      expect(images.first.bytes[0], 0xFF);
      expect(images.first.bytes[1], 0xD8);
    });
  });
}
