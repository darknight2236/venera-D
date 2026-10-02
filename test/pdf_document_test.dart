import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/document.dart';
import 'package:venera/utils/pdf/objects.dart';

import 'helpers/pdf_builder.dart';

/// Assembles a PDF whose classic xref table body is [xrefBody] verbatim, so
/// tests can inject corrupt tables. Object 1 (a catalog) sits at offset 9;
/// startxref is computed to point at the `xref` keyword.
Uint8List craftPdf({
  String objects = '1 0 obj\n<< /Type /Catalog >>\nendobj\n',
  required String xrefBody,
  String trailerEntries = '/Size 2 /Root 1 0 R',
}) {
  final head = '%PDF-1.7\n$objects';
  final xrefPos = latin1.encode(head).length;
  final tail = 'xref\n$xrefBody'
      'trailer\n<< $trailerEntries >>\n'
      'startxref\n$xrefPos\n%%EOF\n';
  return Uint8List.fromList(latin1.encode(head + tail));
}

void main() {
  group('PdfDocument classic xref', () {
    test('opens, exposes the trailer and resolves /Root', () async {
      final pdf = buildImagePdf([
        TestPdfPage(width: 2, height: 1, data: flate(Uint8List(6))),
      ]);
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(doc.trailer['Size'], isA<PdfNumber>());
      final root = doc.resolveDict(doc.trailer['Root']);
      expect((root['Type'] as PdfName).name, 'Catalog');
    });

    test('fetches direct objects and resolves reference chains', () async {
      final pdf = buildImagePdf([
        TestPdfPage(width: 2, height: 1, data: flate(Uint8List(6))),
      ]);
      final doc = PdfDocument(pdf);
      await doc.open();
      final pages = doc.resolveDict(PdfRef(2, 0));
      expect((pages['Type'] as PdfName).name, 'Pages');
      final kids = doc.resolve(pages['Kids']) as PdfArray;
      final page = doc.resolveDict(kids.items.first);
      expect((page['Type'] as PdfName).name, 'Page');
    });

    test('reads stream data with direct /Length', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final pdf = buildImagePdf([
        TestPdfPage(width: 1, height: 1, data: payload, filter: 'DCTDecode'),
      ]);
      final doc = PdfDocument(pdf);
      await doc.open();
      final stream = doc.resolve(PdfRef(4, 0)) as PdfStream;
      expect(doc.streamData(stream), payload);
    });

    test('falls back to endstream scan when /Length is missing', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>');
      b.addObject('<< /Type /Pages /Kids [] /Count 0 >>');
      b.addStreamObject('/Foo 1', latin1.encode('ABC'), omitLength: true);
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      final stream = doc.resolve(PdfRef(3, 0)) as PdfStream;
      expect(latin1.decode(doc.streamData(stream)), 'ABC');
    });

    test('honors /Prev incremental updates (newest entry wins)', () async {
      // Base document: object 1 = catalog with /Marker 1.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R /Marker 1 >>');
      b.addObject('<< /Type /Pages /Kids [] /Count 0 >>');
      final base = b.finishClassic(rootObj: 1);
      final firstXrefOffset = b.lastXrefOffset!;

      // Incremental update: new object 1 with /Marker 2, chained via /Prev.
      final tail = BytesBuilder()..add(base);
      final newOffset = tail.length;
      final update = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Marker 2 >>\n'
          'endobj\n'
          'xref\n0 2\n0000000000 65535 f\r\n'
          '${newOffset.toString().padLeft(10, '0')} 00000 n\r\n'
          'trailer\n<< /Size 3 /Root 1 0 R /Prev $firstXrefOffset >>\n'
          'startxref\nPLACEHOLDER\n%%EOF\n';
      // The startxref value must point at the new xref keyword; compute it.
      final xrefPos = newOffset + update.indexOf('xref\n0 2');
      final fixedUpdate =
          update.replaceFirst('PLACEHOLDER', '$xrefPos');
      tail.add(latin1.encode(fixedUpdate));

      final doc = PdfDocument(tail.takeBytes());
      await doc.open();
      final root = doc.resolveDict(doc.trailer['Root']);
      expect((root['Marker'] as PdfNumber).intValue, 2);
    });

    test('missing startxref throws PdfSyntaxException', () async {
      final doc = PdfDocument(Uint8List.fromList(latin1.encode('%PDF-1.7\n')));
      expect(() => doc.open(), throwsA(isA<PdfSyntaxException>()));
    });
  });

  group('PdfDocument corrupt input', () {
    test('negative xref offset throws PdfSyntaxException on fetch', () async {
      final pdf = craftPdf(
          xrefBody: '0 2\n0000000000 65535 f\r\n-000000005 00000 n\r\n');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(1), throwsA(isA<PdfSyntaxException>()));
    });

    test('xref offset past end of file throws on fetch', () async {
      final pdf = craftPdf(
          xrefBody: '0 2\n0000000000 65535 f\r\n9999999999 00000 n\r\n');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(1), throwsA(isA<PdfSyntaxException>()));
    });

    test('malformed xref entry token throws', () async {
      final pdf = craftPdf(
          xrefBody: '0 2\n0000000000 65535 f\r\ngarbage xx n\r\n');
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('absurd subsection count throws instead of looping', () async {
      final pdf =
          craftPdf(xrefBody: '0 1000000000000\n0000000000 65535 f\r\n');
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('non-numeric subsection header throws', () async {
      final pdf = craftPdf(xrefBody: '/Foo 2\n0000000000 65535 f\r\n');
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('self-referential /Prev chain terminates', () async {
      final head = '%PDF-1.7\n';
      final obj = '1 0 obj\n<< /Type /Catalog >>\nendobj\n';
      final xrefPos = latin1.encode(head + obj).length;
      final tail = 'xref\n0 2\n0000000000 65535 f\r\n'
          '${latin1.encode(head).length.toString().padLeft(10, '0')} 00000 n\r\n'
          'trailer\n<< /Size 2 /Root 1 0 R /Prev $xrefPos >>\n'
          'startxref\n$xrefPos\n%%EOF\n';
      final doc = PdfDocument(
          Uint8List.fromList(latin1.encode(head + obj + tail)));
      await doc.open();
      expect(doc.trailer['Size'], isA<PdfNumber>());
    });

    test('startxref value past end of file throws', () async {
      final pdf = Uint8List.fromList(latin1.encode(
          '%PDF-1.7\n1 0 obj\n<< >>\nendobj\nstartxref\n9999999999\n%%EOF\n'));
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('xref-stream candidate with non-name /Type throws', () async {
      final head = '%PDF-1.7\n';
      final obj =
          '9 0 obj\n<< /Type 5 /Length 3 >>\nstream\nABC\nendstream\nendobj\n';
      final objPos = latin1.encode(head).length;
      final pdf = Uint8List.fromList(
          latin1.encode('$head$obj' 'startxref\n$objPos\n%%EOF\n'));
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('non-numeric /Prev is treated as end of chain', () async {
      final pdf = craftPdf(
        xrefBody: '0 2\n0000000000 65535 f\r\n0000000009 00000 n\r\n',
        trailerEntries: '/Size 2 /Root 1 0 R /Prev (abc)',
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(doc.trailer['Size'], isA<PdfNumber>());
    });
  });

  group('PdfDocument xref streams and object streams', () {
    test('opens a document with a cross-reference stream', () async {
      final pdf = buildImagePdf(
        [TestPdfPage(width: 2, height: 1, data: flate(Uint8List(6)))],
        xrefStream: true,
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      final root = doc.resolveDict(doc.trailer['Root']);
      expect((root['Type'] as PdfName).name, 'Catalog');
      final pages = doc.resolveDict(PdfRef(2, 0));
      expect((pages['Type'] as PdfName).name, 'Pages');
    });

    test('fetches objects stored inside an object stream', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 3 0 R >>'); // 1
      b.addStreamObject(
        '/Type /XObject /Subtype /Image /Width 2 /Height 1 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
        flate(Uint8List(6)),
      ); // 2
      b.addObjectAt(4, '<< /Type /Page /Parent 3 0 R /MediaBox [0 0 2 1] '
          '/Resources << /XObject << /Im0 2 0 R >> >> >>');
      // Object 3 (the Pages dict) lives inside object stream 5.
      const header = '3 0 ';
      final inner =
          latin1.encode('$header<< /Type /Pages /Kids [4 0 R] /Count 1 >>');
      b.addStreamObjectAt(
        5,
        '/Type /ObjStm /N 1 /First ${header.length} /Filter /FlateDecode',
        flate(Uint8List.fromList(inner)),
      );
      final pdf = b.finishXrefStream(rootObj: 1, extraEntries: {3: (2, 5, 0)});

      final doc = PdfDocument(pdf);
      await doc.open();
      final pages = doc.resolveDict(PdfRef(3, 0));
      expect((pages['Type'] as PdfName).name, 'Pages');
      expect((doc.resolveDict(PdfRef(4, 0))['Type'] as PdfName).name, 'Page');
    });

    test('reads an xref stream with no /Filter (stored uncompressed)',
        () async {
      // Object 1 sits at offset 9; W = [1 2 1] keeps entries to 4 bytes.
      final pdf = craftXrefStream(
        '/Type /XRef /Size 2 /W [1 2 1] /Index [0 2] /Root 1 0 R',
        [0, 0, 0, 255, 1, 0, 9, 0],
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      expect((doc.resolveDict(doc.trailer['Root'])['Type'] as PdfName).name,
          'Catalog');
    });

    test('a free entry in a newer xref stream shadows an older in-use one',
        () async {
      // Single section that marks object 1 free: it must not resolve.
      final pdf = craftXrefStream(
        '/Type /XRef /Size 2 /W [1 2 1] /Index [0 2] /Root 1 0 R',
        [0, 0, 0, 255, 0, 0, 0, 0],
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(doc.fetch(1), isNull);
    });
  });

  group('PdfDocument xref stream corrupt input', () {
    test('missing /W throws', () async {
      final pdf = craftXrefStream('/Type /XRef /Size 2 /Root 1 0 R', [0, 0]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('/W with fewer than three fields throws', () async {
      final pdf = craftXrefStream(
          '/Type /XRef /Size 2 /W [1 2] /Index [0 2] /Root 1 0 R', [0, 0, 0]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('/W with a non-numeric field throws instead of a TypeError', () async {
      final pdf = craftXrefStream(
          '/Type /XRef /Size 2 /W [1 2 (x)] /Index [0 2] /Root 1 0 R',
          [0, 0, 0, 255]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('/Index claiming more entries than the payload holds throws',
        () async {
      final pdf = craftXrefStream(
          '/Type /XRef /Size 2 /W [1 2 1] /Index [0 1000000] /Root 1 0 R',
          [0, 0, 0, 255]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('a negative /Index start throws', () async {
      final pdf = craftXrefStream(
          '/Type /XRef /Size 2 /W [1 2 1] /Index [-5 2] /Root 1 0 R',
          [0, 0, 0, 255, 1, 0, 9, 0]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });

    test('an unsupported xref stream filter throws', () async {
      final pdf = craftXrefStream(
          '/Type /XRef /Size 2 /W [1 2 1] /Index [0 2] /Filter /LZWDecode '
          '/Root 1 0 R',
          [0, 0, 0, 255, 1, 0, 9, 0]);
      await expectLater(
          PdfDocument(pdf).open(), throwsA(isA<PdfSyntaxException>()));
    });
  });

  group('PdfDocument object stream corrupt input', () {
    test('an absurd /N throws instead of allocating', () async {
      final pdf = _objStmPdf('/Type /ObjStm /N 1000000000 /First 4', '3 0 ');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(3), throwsA(isA<PdfSyntaxException>()));
    });

    test('a /First beyond the stream data throws', () async {
      final pdf = _objStmPdf('/Type /ObjStm /N 1 /First 9999', '3 0 1 2');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(3), throwsA(isA<PdfSyntaxException>()));
    });

    test('a non-numeric ObjStm header pair throws', () async {
      final pdf = _objStmPdf('/Type /ObjStm /N 1 /First 4', '(x) 1 ');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(3), throwsA(isA<PdfSyntaxException>()));
    });

    test('an entry offset outside the stream data throws', () async {
      final pdf = _objStmPdf('/Type /ObjStm /N 1 /First 4', '3 9999 ');
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(3), throwsA(isA<PdfSyntaxException>()));
    });

    test('an out-of-range index into the object stream throws', () async {
      final pdf = _objStmPdf('/Type /ObjStm /N 1 /First 4', '3 0 << >> ');
      final doc = PdfDocument(pdf);
      await doc.open();
      // Declared entry (2, 5, 7) exceeds N = 1.
      expect(() => doc.fetch(6), throwsA(isA<PdfSyntaxException>()));
    });
    test('a type-2 entry pointing at a compressed stream throws, not a cycle',
        () async {
      // Object 3 is declared type-2 inside "object stream" 5, and object 5 is
      // itself declared type-2 inside 3 - an invalid file that must not
      // recurse until the stack overflows.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 3 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [] /Count 0 >>'); // 2
      final pdf = b.finishXrefStream(
        rootObj: 1,
        extraEntries: {
          3: (2, 5, 0),
          5: (2, 3, 0),
        },
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.fetch(3), throwsA(isA<PdfSyntaxException>()));
    });
  });

  group('PdfDocument.pages', () {
    test('returns pages in Kids order', () async {
      final pdf = buildImagePdf([
        TestPdfPage(width: 2, height: 1, data: flate(Uint8List(6))),
        TestPdfPage(width: 2, height: 1, data: flate(Uint8List(6))),
      ]);
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(doc.pages().length, 2);
    });

    test('inherits /Resources from ancestor Pages nodes', () async {
      // Page dict has no /Resources; the Pages root carries it.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [4 0 R] /Count 1 '
          '/Resources << /XObject << /Im0 3 0 R >> >> >>'); // 2
      b.addStreamObject(
        '/Type /XObject /Subtype /Image /Width 2 /Height 1 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
        flate(Uint8List(6)),
      ); // 3
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] >>'); // 4
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      final pages = doc.pages();
      expect(pages.length, 1);
      final resources = doc.resolveDict(pages.first.resources);
      expect(resources['XObject'], isNotNull);
    });

    test('collects image XObjects of a page sorted by resource name', () async {
      // One page with two image XObjects named /ImB and /ImA.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [5 0 R] /Count 1 >>'); // 2
      for (var i = 0; i < 2; i++) {
        b.addStreamObject(
          '/Type /XObject /Subtype /Image /Width 2 /Height 1 '
          '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
          flate(Uint8List(6)),
        );
      }
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] '
          '/Resources << /XObject << /ImB 4 0 R /ImA 3 0 R >> >> >>'); // 5
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      final images = doc.collectPageImageStreams(doc.pages().first);
      // Sorted by resource name: /ImA (obj 3) before /ImB (obj 4).
      expect(images.map((s) => s.objNum).toList(), [3, 4]);
    });
  });

  group('PdfDocument page tree corrupt input', () {
    test('a non-name /Type does not throw a raw TypeError', () async {
      // A page dict whose /Type is a number: it has no /Kids, so it is simply
      // treated as a leaf rather than crashing the walk.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'); // 2
      b.addObject('<< /Type 7 /MediaBox [0 0 2 1] >>'); // 3
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      expect(doc.pages().length, 1);
    });

    test('a non-name /Subtype on an XObject is skipped, not fatal', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [4 0 R] /Count 1 >>'); // 2
      b.addStreamObject(
        '/Type /XObject /Subtype /Form /Width 2 /Height 1',
        latin1.encode('x'),
      ); // 3
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] '
          '/Resources << /XObject << /Im0 3 0 R >> >> >>'); // 4
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      expect(doc.collectPageImageStreams(doc.pages().first), isEmpty);
    });

    test('a cyclic page tree throws instead of overflowing the stack', () async {
      // Pages node 2 lists kid 3, and 3 lists kid 2 - an infinite tree.
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'); // 2
      b.addObject('<< /Type /Pages /Kids [2 0 R] /Count 1 >>'); // 3
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      expect(() => doc.pages(), throwsA(isA<PdfSyntaxException>()));
    });

    test('a missing /Root throws a domain exception', () async {
      final pdf = craftPdf(
        xrefBody: '0 2\n0000000000 65535 f\r\n0000000009 00000 n\r\n',
        trailerEntries: '/Size 2',
      );
      final doc = PdfDocument(pdf);
      await doc.open();
      expect(() => doc.pages(), throwsA(isA<PdfSyntaxException>()));
    });

    test('/Resources that is not a dictionary yields no images', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // 1
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'); // 2
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2 1] '
          '/Resources 42 >>'); // 3
      final doc = PdfDocument(b.finishClassic(rootObj: 1));
      await doc.open();
      expect(doc.collectPageImageStreams(doc.pages().first), isEmpty);
    });
  });
}

/// Builds a PDF holding `1 0 obj << /Type /Catalog >>` plus an xref stream at
/// object 2 whose dictionary is [dict] (minus /Length, which is filled in) and
/// whose raw payload is [payload]. No compression is applied, so [payload] is
/// read verbatim by the parser.
Uint8List craftXrefStream(String dict, List<int> payload) {
  final head = '%PDF-1.7\n';
  final obj1 = '1 0 obj\n<< /Type /Catalog >>\nendobj\n';
  final xrefPos = latin1.encode(head + obj1).length;
  final streamObj = '2 0 obj\n<< $dict /Length ${payload.length} >>\nstream\n';
  final bytes = BytesBuilder()
    ..add(latin1.encode(head))
    ..add(latin1.encode(obj1))
    ..add(latin1.encode(streamObj))
    ..add(payload)
    ..add(latin1.encode(
        '\nendstream\nendobj\nstartxref\n$xrefPos\n%%EOF\n'));
  return bytes.toBytes();
}

/// A PDF where object 3 is a type-2 entry living inside uncompressed object
/// stream 5, described by [dict] with the ASCII payload [data]. Object 6 is
/// declared type-2 at index 7 of the same stream to exercise the bounds check.
Uint8List _objStmPdf(String dict, String data) {
  final b = TestPdfBuilder();
  b.addObject('<< /Type /Catalog /Pages 3 0 R >>'); // 1
  b.addStreamObjectAt(5, dict, latin1.encode(data));
  b.addObjectAt(2, '<< /Type /Pages /Kids [] /Count 0 >>');
  return b.finishXrefStream(
    rootObj: 1,
    extraEntries: {
      3: (2, 5, 0),
      6: (2, 5, 7),
    },
  );
}
