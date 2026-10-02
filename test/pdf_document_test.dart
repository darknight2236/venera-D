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
}
