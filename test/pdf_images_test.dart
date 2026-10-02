import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';

import 'helpers/pdf_builder.dart';

/// 2x1 RGB pixels: red, blue.
Uint8List rgb2x1() => Uint8List.fromList([
      255, 0, 0, 0, 0, 255,
    ]);

Future<List<int>> decodePngPixels(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final rgba =
      (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return [
    rgba.getUint8(0), rgba.getUint8(1), rgba.getUint8(2), // pixel 1 RGB
    rgba.getUint8(4), rgba.getUint8(5), rgba.getUint8(6), // pixel 2 RGB
  ];
}

/// A one-page PDF whose image XObject dictionary is exactly [imageDict] and
/// whose stream payload is [data], so tests can declare arbitrary
/// (including malformed) image attributes.
Uint8List pdfWithImage(String imageDict, List<int> data) {
  final b = TestPdfBuilder();
  b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
  b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'); // 2
  b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] '
      '/Resources << /XObject << /Im0 4 0 R >> >> >>'); // 3
  b.addStreamObject('/Type /XObject /Subtype /Image $imageDict', data); // 4
  return b.finishClassic(rootObj: 1);
}

void main() {
  group('extractPdfImages (unencrypted)', () {
    test('FlateDecode RGB pages become PNGs with identical pixels', () async {
      final pdf = buildImagePdf([
        TestPdfPage(width: 2, height: 1, data: flate(rgb2x1())),
        TestPdfPage(width: 2, height: 1, data: flate(rgb2x1())),
      ]);
      final images = await extractPdfImages(pdf).toList();
      expect(images.length, 2);
      expect(images[0].pageIndex, 0);
      expect(images[1].pageIndex, 1);
      expect(images[0].extension, 'png');
      expect(await decodePngPixels(images[0].bytes), [255, 0, 0, 0, 0, 255]);
    });

    test('DeviceGray pages expand to gray RGB', () async {
      final pdf = buildImagePdf([
        TestPdfPage(
          width: 2,
          height: 1,
          data: flate(Uint8List.fromList([0, 255])),
          colorSpace: 'DeviceGray',
        ),
      ]);
      final images = await extractPdfImages(pdf).toList();
      expect(await decodePngPixels(images.single.bytes),
          [0, 0, 0, 255, 255, 255]);
    });

    test('DCTDecode streams pass through byte-identical', () async {
      // Passthrough does not validate JPEG content; sentinel bytes are fine.
      final fakeJpeg =
          Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 4, 5, 0xFF, 0xD9]);
      final pdf = buildImagePdf([
        TestPdfPage(
            width: 1, height: 1, data: fakeJpeg, filter: 'DCTDecode'),
      ]);
      final images = await extractPdfImages(pdf).toList();
      expect(images.single.extension, 'jpg');
      expect(images.single.bytes, fakeJpeg);
    });

    test('xref-stream documents extract identically', () async {
      final pdf = buildImagePdf(
        [TestPdfPage(width: 2, height: 1, data: flate(rgb2x1()))],
        xrefStream: true,
      );
      final images = await extractPdfImages(pdf).toList();
      expect(await decodePngPixels(images.single.bytes), [255, 0, 0, 0, 0, 255]);
    });

    test('a document without images throws PdfNoImagesException', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>');
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>');
      final pdf = b.finishClassic(rootObj: 1);
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfNoImagesException>()),
      );
    });

    test('unsupported encodings report the 1-based page number', () async {
      final pdf = buildImagePdf([
        TestPdfPage(width: 1, height: 1, data: Uint8List(4), filter: 'JPXDecode'),
      ]);
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfUnsupportedEncodingException>()
            .having((e) => e.page, 'page', 1)
            .having((e) => e.filter, 'filter', 'JPXDecode')),
      );
    });
  });

  group('extractPdfImages colour spaces', () {
    test('/ICCBased maps to the device space named by its /N', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'); // 2
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] '
          '/Resources << /XObject << /Im0 4 0 R >> >> >>'); // 3
      b.addStreamObject(
        '/Type /XObject /Subtype /Image /Width 2 /Height 1 '
        '/BitsPerComponent 8 /Filter /FlateDecode '
        '/ColorSpace [/ICCBased 5 0 R]',
        flate(Uint8List.fromList([0, 255])),
      ); // 4
      b.addStreamObject('/N 1', latin1.encode('icc profile bytes')); // 5
      final images = await extractPdfImages(b.finishClassic(rootObj: 1)).toList();
      expect(await decodePngPixels(images.single.bytes),
          [0, 0, 0, 255, 255, 255]);
    });

    test('/Indexed expands indices through the palette table', () async {
      // Palette: index 0 = red, index 1 = green.
      final pdf = pdfWithImage(
        '/Width 2 /Height 1 /BitsPerComponent 8 /Filter /FlateDecode '
        '/ColorSpace [/Indexed /DeviceRGB 1 <FF000000FF00>]',
        flate(Uint8List.fromList([0, 1])),
      );
      final images = await extractPdfImages(pdf).toList();
      expect(await decodePngPixels(images.single.bytes),
          [255, 0, 0, 0, 255, 0]);
    });

    test('a stencil /ImageMask is skipped, not treated as a page image',
        () async {
      final pdf = pdfWithImage(
        '/Width 2 /Height 1 /BitsPerComponent 1 /ImageMask true '
        '/Filter /FlateDecode',
        flate(Uint8List.fromList([0xF0])),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfNoImagesException>()),
      );
    });
  });

  group('extractPdfImages corrupt image dictionaries', () {
    test('a non-numeric /Width throws a domain error, not a TypeError',
        () async {
      final pdf = pdfWithImage(
        '/Width (oops) /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB',
        Uint8List.fromList([0, 0, 0]),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfExtractException>()),
      );
    });

    test('a non-numeric /Decode entry throws a domain error', () async {
      final pdf = pdfWithImage(
        '/Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB '
        '/Decode [(x) 1]',
        Uint8List.fromList([0, 0, 0]),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfExtractException>()),
      );
    });

    test('a truncated /Indexed colour space throws a domain error', () async {
      final pdf = pdfWithImage(
        '/Width 2 /Height 1 /BitsPerComponent 8 /Filter /FlateDecode '
        '/ColorSpace [/Indexed /DeviceRGB]',
        flate(Uint8List.fromList([0])),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfExtractException>()),
      );
    });

    test('sample data shorter than the declared geometry throws', () async {
      // 2x2 RGB needs 12 bytes; supply 6.
      final pdf = pdfWithImage(
        '/Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceRGB '
        '/Filter /FlateDecode',
        flate(Uint8List(6)),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfExtractException>()),
      );
    });

    test('an unsupported BitsPerComponent throws a domain error', () async {
      final pdf = pdfWithImage(
        '/Width 2 /Height 1 /BitsPerComponent 4 /ColorSpace /DeviceRGB '
        '/Filter /FlateDecode',
        flate(Uint8List.fromList([0x12, 0x34, 0x50])),
      );
      await expectLater(
        extractPdfImages(pdf).toList(),
        throwsA(isA<PdfExtractException>()),
      );
    });
  });

  group('applyPredictorInverse', () {
    test('PNG Up filter (2) reconstructs rows', () {
      // 1 row of 2 gray pixels, filter byte 2 (Up), previous row = zeros.
      final data = Uint8List.fromList([2, 10, 20]);
      final out = applyPredictorInverse(data,
          predictor: 12, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 20]);
    });

    test('PNG Sub filter (1) accumulates within the row', () {
      final data = Uint8List.fromList([1, 10, 5]);
      final out = applyPredictorInverse(data,
          predictor: 12, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 15]);
    });

    test('PNG Average filter (3) averages left and up', () {
      final data = Uint8List.fromList([3, 10, 5]);
      final out = applyPredictorInverse(data,
          predictor: 12, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 10]);
    });

    test('PNG Paeth filter (4) picks the left predictor', () {
      final data = Uint8List.fromList([4, 10, 5]);
      final out = applyPredictorInverse(data,
          predictor: 12, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 15]);
    });

    test('TIFF predictor (2) accumulates per component', () {
      final data = Uint8List.fromList([10, 5]);
      final out = applyPredictorInverse(data,
          predictor: 2, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 15]);
    });

    test('predictor 1 is a no-op', () {
      final data = Uint8List.fromList([1, 2, 3]);
      expect(
          applyPredictorInverse(data,
              predictor: 1, columns: 3, colors: 1, bpc: 8),
          data);
    });

    test('an unknown predictor throws a domain error', () {
      expect(
        () => applyPredictorInverse(Uint8List(4),
            predictor: 99, columns: 2, colors: 1, bpc: 8),
        throwsA(isA<PdfExtractException>()),
      );
    });

    test('a truncated final row does not read past the buffer', () {
      // Declares 2 rows of 2 bytes plus a filter byte, but holds only one row.
      final data = Uint8List.fromList([0, 10, 20]);
      final out = applyPredictorInverse(data,
          predictor: 12, columns: 2, colors: 1, bpc: 8);
      expect(out, [10, 20]);
    });
  });

  group('toRgb8', () {
    test('CMYK (Adobe-inverted via /Decode) converts to RGB', () {
      // Adobe-inverted CMYK: R = C*K/255.
      final cmyk = Uint8List.fromList([255, 128, 0, 255]);
      final rgb = toRgb8(cmyk, 'DeviceCMYK', 1, 1,
          decode: [1, 0, 1, 0, 1, 0, 1, 0]);
      expect(rgb, [255, 128, 0]);
    });

    test('non-inverted CMYK converts via (255-X)(255-K)/255', () {
      final cmyk = Uint8List.fromList([0, 0, 0, 0]); // C=M=Y=K=0 -> white
      final rgb = toRgb8(cmyk, 'DeviceCMYK', 1, 1);
      expect(rgb, [255, 255, 255]);
    });

    test('16-bit samples downsample to 8-bit by rounding', () {
      final samples = Uint8List.fromList([0xFF, 0xFF, 0x00, 0x00]); // gray 16b
      final rgb = toRgb8(samples, 'DeviceGray', 1, 1, bpc: 16);
      expect(rgb, [255, 255, 255]);
    });

    test('an unknown colour space throws a domain error', () {
      expect(
        () => toRgb8(Uint8List(4), 'Lab', 1, 1),
        throwsA(isA<PdfExtractException>()),
      );
    });
  });
}
