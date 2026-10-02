import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/objects.dart';

PdfObject parse(String source) =>
    PdfParser(Uint8List.fromList(latin1.encode(source)), 0).parseObject();

PdfParser parserOf(String source) =>
    PdfParser(Uint8List.fromList(latin1.encode(source)), 0);

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
      final s = parse(src) as PdfStream;
      expect(latin1.decode(s.raw), 'XYZ');
    });
  });

  group('PdfParser stream length recovery', () {
    test('scans for endstream when /Length is absent', () {
      final s =
          parse('<< /Filter /DCTDecode >>\nstream\nABCDEFGHIJ\nendstream')
              as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDEFGHIJ');
    });

    test('scans for endstream when /Length is an indirect reference', () {
      final s =
          parse('<< /Length 7 0 R >>\nstream\nABCDEFGHIJ\nendstream')
              as PdfStream;
      expect(s.dict['Length'], isA<PdfRef>());
      expect(latin1.decode(s.raw), 'ABCDEFGHIJ');
    });

    test('scans for endstream when /Length is negative', () {
      final s = parse('<< /Length -1 >>\nstream\nABCDEFGHIJ\nendstream')
          as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDEFGHIJ');
    });

    test('recovers from a wrong but in-bounds /Length', () {
      final s = parse('<< /Length 3 >>\nstream\nABCDEFGHIJ\nendstream')
          as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDEFGHIJ');
    });

    test('accepts a correct /Length with no EOL before endstream', () {
      final s = parse('<< /Length 5 >>\nstream\nABCDEendstream') as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDE');
    });

    test('trusts a verifying /Length over an earlier endstream in the data',
        () {
      final s =
          parse('<< /Length 20 >>\nstream\nxxendstreamxxxxxxxxx\nendstream')
              as PdfStream;
      expect(latin1.decode(s.raw), 'xxendstreamxxxxxxxxx');
    });

    test('throws when neither /Length nor endstream is usable', () {
      expect(() => parse('<< /Length 3 >>\nstream\nABC'),
          throwsA(isA<PdfSyntaxException>()));
    });
  });

  group('PdfParser malformed input', () {
    test('unterminated literal string', () {
      expect(() => parse('(abc'), throwsA(isA<PdfSyntaxException>()));
    });

    test('unterminated array', () {
      expect(() => parse('[1 2'), throwsA(isA<PdfSyntaxException>()));
    });

    test('unterminated dictionary', () {
      expect(() => parse('<< /A 1'), throwsA(isA<PdfSyntaxException>()));
    });

    test('unterminated hex string leaves pos inside the buffer', () {
      final p = parserOf('<41');
      expect(p.parseObject, throwsA(isA<PdfSyntaxException>()));
      expect(p.pos, lessThanOrEqualTo(p.bytes.length));
    });

    test('junk byte', () {
      expect(() => parse('@'), throwsA(isA<PdfSyntaxException>()));
    });
  });

  group('PdfParser hostile numerics', () {
    test('a huge /Length falls back to the endstream scan', () {
      // 1e23 rounds to int64-max, so dataStart + intValue wraps negative,
      // passes an integer bounds check and makes sublistView throw RangeError.
      final s = parse(
              '<< /Length 99999999999999999999999 >>\nstream\nABCDEFGHIJ\nendstream')
          as PdfStream;
      expect(latin1.decode(s.raw), 'ABCDEFGHIJ');
    });

    test('rejects a number literal that overflows to Infinity', () {
      // intValue on Infinity throws UnsupportedError, which is not an
      // Exception and would escape the import error handler.
      expect(() => parse('1' * 400), throwsA(isA<PdfSyntaxException>()));
    });

    test('an over-long generation run stays a number', () {
      // int.parse on a 29-digit run throws FormatException from inside the
      // reference lookahead.
      expect(parse('12 ${'9' * 29} R'), isA<PdfNumber>());
      expect((parse('12 ${'9' * 29} R') as PdfNumber).intValue, 12);
    });
  });

  group('PdfParser nesting limit', () {
    test('rejects nesting beyond the limit', () {
      // StackOverflowError is not an Exception, so the import error handler
      // cannot catch it; the parser has to bound lexical nesting itself.
      // Balanced brackets, so this cannot be satisfied by the unterminated
      // array path.
      expect(() => parse('${'[' * 200}${']' * 200}'),
          throwsA(isA<PdfSyntaxException>()));
    });

    test('still parses nesting within the limit', () {
      final a = parse('${'[' * 10}1${']' * 10}') as PdfArray;
      var cur = a;
      for (var i = 0; i < 9; i++) {
        cur = cur.items.single as PdfArray;
      }
      expect((cur.items.single as PdfNumber).intValue, 1);
    });

    test('balances the depth counter across sibling objects', () {
      final nested = '${'[' * 20}1${']' * 20}';
      final p = parserOf('$nested $nested');
      expect(p.parseObject(), isA<PdfArray>());
      expect(p.parseObject(), isA<PdfArray>());
    });
  });
}
