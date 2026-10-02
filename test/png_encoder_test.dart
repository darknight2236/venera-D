import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/png_encoder.dart';

void main() {
  group('crc32', () {
    test('matches the standard check value', () {
      // CRC-32 of "123456789" is 0xCBF43926
      expect(crc32('123456789'.codeUnits), 0xCBF43926);
    });
  });

  group('encodePng', () {
    test('output has the PNG signature and IHDR/IDAT/IEND chunks', () {
      final png = encodePng(
        width: 2,
        height: 2,
        channels: 3,
        samples: Uint8List(12),
      );
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
      // IHDR: width=2, height=2, depth=8, colorType=2 (truecolor)
      expect(png[19], 2);
      expect(png[23], 2);
      expect(png[24], 8);
      expect(png[25], 2);
    });

    test('grayscale uses color type 0', () {
      final png = encodePng(
        width: 1,
        height: 1,
        channels: 1,
        samples: Uint8List.fromList([128]),
      );
      expect(png[25], 0);
    });

    test('RGB pixels survive a decode round-trip', () async {
      final samples = Uint8List.fromList([
        255, 0, 0, 0, 255, 0, // row 1: red, green
        0, 0, 255, 255, 255, 255, // row 2: blue, white
      ]);
      final png =
          encodePng(width: 2, height: 2, channels: 3, samples: samples);
      final codec = await ui.instantiateImageCodec(png);
      expect(codec.frameCount, 1);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2);
      expect(frame.image.height, 2);
      final rgba =
          (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Pixel (0,0) red
      expect([rgba.getUint8(0), rgba.getUint8(1), rgba.getUint8(2)],
          [255, 0, 0]);
      // Pixel (1,1) white
      expect([rgba.getUint8(12), rgba.getUint8(13), rgba.getUint8(14)],
          [255, 255, 255]);
    });
  });
}
