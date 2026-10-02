// test/pdf_objects_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/objects.dart';

PdfObject parse(String source) =>
    PdfParser(Uint8List.fromList(latin1.encode(source)), 0).parseObject();

void main() {
  group('PdfParser primitives', () {
    test('parses numbers (int and real)', () {
      expect((parse('42') as PdfNumber).intValue, 42);
      expect((parse('-3.5') as PdfNumber).value, -3.5);
    });

    test('parses booleans and null', () {
      expect((parse('true') as PdfBool).value, isTrue);
      expect((parse('false') as PdfBool).value, isFalse);
      expect(parse('null'), isA<PdfNull>());
    });

    test('parses names with #XX escapes', () {
      expect((parse('/Name') as PdfName).name, 'Name');
      expect((parse('/A#23B') as PdfName).name, 'A#B');
    });

    test('parses literal strings with escapes and nested parens', () {
      final s = parse(r'(a\(b(c)d\n\t\101)') as PdfString;
      expect(latin1.decode(s.bytes), 'a(b(c)d\n\tA');
    });

    test('parses hex strings with odd-length padding', () {
      // ISO 32000 7.3.4.3: odd digit count implies a trailing 0, so the last
      // byte is 0x30 ('0'), not 0x33.
      final s = parse('<48656C6C6F3>') as PdfString;
      expect(latin1.decode(s.bytes), 'Hello0');
    });

    test('skips comments', () {
      expect((parse('%not this\n7') as PdfNumber).intValue, 7);
    });
  });

  group('PdfParser composite', () {
    test('parses arrays of mixed values', () {
      final a = parse('[1 /Two (three) true [4]]') as PdfArray;
      expect(a.items.length, 5);
      expect((a.items[0] as PdfNumber).intValue, 1);
      expect((a.items[1] as PdfName).name, 'Two');
      expect((a.items[4] as PdfArray).items.length, 1);
    });

    test('parses dictionaries', () {
      final d = parse('<< /Type /Page /Count 3 /Kids [1 0 R] >>') as PdfDictionary;
      expect((d['Type'] as PdfName).name, 'Page');
      expect((d['Count'] as PdfNumber).intValue, 3);
      final kids = d['Kids'] as PdfArray;
      expect((kids.items[0] as PdfRef).number, 1);
    });

    test('parses indirect references with lookahead', () {
      final r = parse('12 0 R') as PdfRef;
      expect(r.number, 12);
      expect(r.generation, 0);
      // A plain number not followed by "G R" stays a number.
      expect(parse('12 0'), isA<PdfNumber>());
    });

    test('parses streams with direct /Length', () {
      final src = '<< /Length 5 >>\nstream\nABCDE\nendstream';
      final s = parse(src) as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDE');
      expect((s.dict['Length'] as PdfNumber).intValue, 5);
    });

    test('parses streams with CRLF after the stream keyword', () {
      final src = '<< /Length 3 >>\rstream\r\nXYZ\r\nendstream';
      // "stream" may be followed by \r\n or \n; data is exactly 3 bytes.
      final s = PdfParser(
        Uint8List.fromList(latin1.encode(src.replaceAll('\rstream', 'stream'))),
        0,
      ).parseObject() as PdfStream;
      expect(latin1.decode(s.raw), 'XYZ');
    });
  });
}
