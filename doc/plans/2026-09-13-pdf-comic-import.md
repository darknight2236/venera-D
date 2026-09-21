# 图片型漫画 PDF 导入 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持导入图片型漫画 PDF（含用户密码加密的 PDF），行为与现有 cbz 导入对齐。

**Architecture:** 纯 Dart 自研 PDF 子集解析器（`lib/utils/pdf/`），DCTDecode JPEG 字节直通、FlateDecode 转手写 PNG；加密走标准安全处理器 R2-R6（复用已有 `crypto`/`pointycastle` 依赖，零新增）；提取的图片落盘到缓存目录后复用 CBZ 导入的注册尾段；密码通过注入的 `passwordProvider` 回调向 UI 索取。

**Tech Stack:** Dart 3.8 / Flutter 3.44.6；dart:io zlib；crypto（MD5/SHA）；pointycastle（AES）；手写 RC4 与 PNG 编码器；flutter_test。

**规格:** `doc/specs/2026-09-13-pdf-comic-import-design.md`（已获用户批准）

**约定（本仓库特有，实施者必须遵守）:**
- 提交信息：conventional commits 英文（`feat:` / `fix:` / `test:` / `docs:`），每个任务一个提交
- 测试命令：`flutter test <文件>`（单文件）或 `flutter test`（全量）；当前基线 184 个测试全绿
- `flutter analyze` 必须零告警后才能提交
- foundation/ 的改动必须带测试（AGENTS.md 要求）
- 分层规则：utils/ 可 import foundation/，不可 import pages/ 或 components/（架构测试会拦截）
- 不要运行 `flutter build`（CI 专属）；不要 commit `log(1).txt`

**任务依赖链:** 1→(2→3→4→5→6)→7→8→9→10→(11)→12→13→14。任务 1 与任务 11 可与解析链并行。

---

### Task 1: PNG 编码器（png_encoder.dart）

**Files:**
- Create: `lib/utils/pdf/png_encoder.dart`
- Test: `test/png_encoder_test.dart`

- [ ] **Step 1.1: 写失败测试**

```dart
// test/png_encoder_test.dart
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
```

- [ ] **Step 1.2: 运行确认失败**

Run: `flutter test test/png_encoder_test.dart`
Expected: FAIL（编译错误：`png_encoder.dart` 不存在）

- [ ] **Step 1.3: 实现**

```dart
// lib/utils/pdf/png_encoder.dart
import 'dart:io';
import 'dart:typed_data';

/// Minimal 8-bit PNG encoder (grayscale and truecolor RGB), hand-rolled in
/// the same spirit as the PDF writer in utils/pdf.dart. Only what the PDF
/// import needs: filter-0 scanlines, a single IDAT, no ancillary chunks.

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// Standard CRC-32 (IEEE 802.3 polynomial), as used by PNG chunks.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Encodes 8-bit samples into a PNG file image.
///
/// [channels] must be 1 (grayscale) or 3 (RGB); [samples] must have exactly
/// `width * height * channels` bytes.
Uint8List encodePng({
  required int width,
  required int height,
  required int channels,
  required Uint8List samples,
}) {
  assert(channels == 1 || channels == 3);
  assert(samples.length == width * height * channels);
  final rowBytes = width * channels;
  final raw = Uint8List((rowBytes + 1) * height);
  for (var y = 0; y < height; y++) {
    raw[y * (rowBytes + 1)] = 0; // filter type: None
    raw.setRange(
      y * (rowBytes + 1) + 1,
      (y + 1) * (rowBytes + 1),
      samples,
      y * rowBytes,
    );
  }
  final compressed = Uint8List.fromList(ZLibEncoder().convert(raw));

  final out = BytesBuilder();
  void chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    final typeBytes = type.codeUnits;
    out.add(typeBytes);
    out.add(data);
    final crc = ByteData(4)
      ..setUint32(0, crc32([...typeBytes, ...data]));
    out.add(crc.buffer.asUint8List());
  }

  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, channels == 3 ? 2 : 0) // color type: truecolor / grayscale
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter
    ..setUint8(12, 0); // interlace: none
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', compressed);
  chunk('IEND', const []);
  return out.takeBytes();
}
```

- [ ] **Step 1.4: 运行确认通过**

Run: `flutter test test/png_encoder_test.dart`
Expected: PASS（4 个测试）

- [ ] **Step 1.5: 提交**

```bash
git add lib/utils/pdf/png_encoder.dart test/png_encoder_test.dart
git commit -m "feat: hand-rolled minimal PNG encoder for the PDF import pipeline"
```

---

### Task 2: PDF 对象模型与词法/语法解析器（pdf/objects.dart）

**Files:**
- Create: `lib/utils/pdf/objects.dart`
- Test: `test/pdf_objects_test.dart`

- [ ] **Step 2.1: 写失败测试**

```dart
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
      final s = parse('<48656C6C6F3>') as PdfString;
      expect(latin1.decode(s.bytes), 'Hello3');
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
```

- [ ] **Step 2.2: 运行确认失败**

Run: `flutter test test/pdf_objects_test.dart`
Expected: FAIL（编译错误：objects.dart 不存在）

- [ ] **Step 2.3: 实现**

```dart
// lib/utils/pdf/objects.dart
import 'dart:convert';
import 'dart:typed_data';

/// Base class of the PDF object model. Instances are produced by [PdfParser].
abstract class PdfObject {}

class PdfNull extends PdfObject {
  const PdfNull();
}

class PdfBool extends PdfObject {
  final bool value;
  const PdfBool(this.value);
}

class PdfNumber extends PdfObject {
  final double value;
  const PdfNumber(this.value);
  int get intValue => value.round();
}

/// A literal or hexadecimal string. Content bytes are kept raw (string
/// decryption is intentionally not implemented: nothing in the image
/// extraction path consumes string values).
class PdfString extends PdfObject {
  final Uint8List bytes;
  PdfString(this.bytes);
}

class PdfName extends PdfObject {
  /// Name without the leading slash; #XX escapes already decoded.
  final String name;
  const PdfName(this.name);
}

class PdfArray extends PdfObject {
  final List<PdfObject> items;
  PdfArray(this.items);
}

class PdfDictionary extends PdfObject {
  /// Keys are names without the leading slash.
  final Map<String, PdfObject> map;
  PdfDictionary(this.map);
  PdfObject? operator [](String key) => map[key];
}

class PdfRef extends PdfObject {
  final int number;
  final int generation;
  const PdfRef(this.number, this.generation);
}

class PdfStream extends PdfObject {
  final PdfDictionary dict;

  /// Raw bytes between 'stream' and 'endstream', before decryption and
  /// before /Filter decoding.
  Uint8List raw;

  /// Object coordinates, filled in by the document when fetching; needed for
  /// per-object decryption keys (R2-R4).
  int objNum = 0;
  int objGen = 0;

  PdfStream(this.dict, this.raw);
}

/// Recursive-descent parser over a PDF byte buffer. Parses a single object
/// per call starting at [pos]; `pos` advances past what was consumed.
class PdfParser {
  PdfParser(this.bytes, this.pos);

  final Uint8List bytes;
  int pos;

  static bool isWhitespace(int c) =>
      c == 0x00 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20;

  static bool isDelimiter(int c) =>
      c == 0x28 || // (
      c == 0x29 || // )
      c == 0x3C || // <
      c == 0x3E || // >
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x7B || // {
      c == 0x7D || // }
      c == 0x2F || // /
      c == 0x25; // %

  void skipWhitespaceAndComments() {
    while (pos < bytes.length) {
      final c = bytes[pos];
      if (isWhitespace(c)) {
        pos++;
      } else if (c == 0x25) {
        while (pos < bytes.length && bytes[pos] != 0x0A && bytes[pos] != 0x0D) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  /// Consumes [kw] when it appears at the current position as a whole token.
  bool matchKeyword(String kw) {
    if (pos + kw.length > bytes.length) return false;
    for (var i = 0; i < kw.length; i++) {
      if (bytes[pos + i] != kw.codeUnitAt(i)) return false;
    }
    final after = pos + kw.length;
    if (after < bytes.length) {
      final c = bytes[after];
      if (!isWhitespace(c) && !isDelimiter(c)) return false;
    }
    pos = after;
    return true;
  }

  /// Reads one whitespace-delimited token (used for classic xref entries).
  String readToken() {
    skipWhitespaceAndComments();
    final start = pos;
    while (pos < bytes.length) {
      final c = bytes[pos];
      if (isWhitespace(c) || isDelimiter(c)) break;
      pos++;
    }
    if (pos == start) throw const PdfSyntaxException('Expected a token');
    return latin1.decode(bytes.sublist(start, pos));
  }

  /// Parses one object value. Handles the `N G R` indirect-reference
  /// lookahead and `<< ... >> stream` bodies.
  PdfObject parseObject() {
    skipWhitespaceAndComments();
    if (pos >= bytes.length) {
      throw const PdfSyntaxException('Unexpected end of file');
    }
    final c = bytes[pos];
    if (c == 0x28) return PdfString(_parseLiteralStringBytes());
    if (c == 0x3C) {
      if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3C) {
        return _parseDictOrStream();
      }
      return _parseHexString();
    }
    if (c == 0x2F) return _parseName();
    if (c == 0x5B) return _parseArray();
    if (matchKeyword('true')) return const PdfBool(true);
    if (matchKeyword('false')) return const PdfBool(false);
    if (matchKeyword('null')) return const PdfNull();
    return _parseNumberOrRef();
  }

  PdfObject _parseNumberOrRef() {
    final start = pos;
    while (pos < bytes.length) {
      final c = bytes[pos];
      final isNumChar =
          (c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2D || c == 0x2E;
      if (!isNumChar) break;
      pos++;
    }
    if (pos == start) {
      throw PdfSyntaxException(
          'Unexpected byte 0x${bytes[start].toRadixString(16)} at offset $start');
    }
    final text = latin1.decode(bytes.sublist(start, pos));
    final value = double.tryParse(text);
    if (value == null) {
      throw PdfSyntaxException('Invalid number "$text" at offset $start');
    }
    // Indirect-reference lookahead: integer, generation, 'R'.
    if (!text.contains('.') && value == value.roundToDouble()) {
      final saved = pos;
      try {
        skipWhitespaceAndComments();
        final genStart = pos;
        while (pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x39) {
          pos++;
        }
        if (pos > genStart) {
          final gen = int.parse(latin1.decode(bytes.sublist(genStart, pos)));
          skipWhitespaceAndComments();
          if (matchKeyword('R')) {
            return PdfRef(value.toInt(), gen);
          }
        }
      } on PdfSyntaxException {
        // Fall through to restore.
      }
      pos = saved;
    }
    return PdfNumber(value);
  }

  PdfObject _parseName() {
    pos++; // '/'
    final sb = StringBuffer();
    while (pos < bytes.length) {
      final c = bytes[pos];
      if (isWhitespace(c) || isDelimiter(c)) break;
      if (c == 0x23 && pos + 2 < bytes.length) {
        final hex = latin1.decode(bytes.sublist(pos + 1, pos + 3));
        final code = int.tryParse(hex, radix: 16);
        if (code != null) {
          sb.writeCharCode(code);
          pos += 3;
          continue;
        }
      }
      sb.writeCharCode(c);
      pos++;
    }
    return PdfName(sb.toString());
  }

  Uint8List _parseLiteralStringBytes() {
    pos++; // '('
    final out = BytesBuilder();
    var depth = 1;
    while (pos < bytes.length) {
      var c = bytes[pos];
      if (c == 0x5C) {
        pos++;
        if (pos >= bytes.length) break;
        c = bytes[pos];
        switch (c) {
          case 0x6E:
            out.addByte(0x0A);
            pos++;
          case 0x72:
            out.addByte(0x0D);
            pos++;
          case 0x74:
            out.addByte(0x09);
            pos++;
          case 0x62:
            out.addByte(0x08);
            pos++;
          case 0x66:
            out.addByte(0x0C);
            pos++;
          case 0x28:
            out.addByte(0x28);
            pos++;
          case 0x29:
            out.addByte(0x29);
            pos++;
          case 0x5C:
            out.addByte(0x5C);
            pos++;
          case 0x0A:
            pos++;
          case 0x0D:
            pos++;
            if (pos < bytes.length && bytes[pos] == 0x0A) pos++;
          default:
            if (c >= 0x30 && c <= 0x37) {
              var oct = 0;
              var n = 0;
              while (n < 3 &&
                  pos < bytes.length &&
                  bytes[pos] >= 0x30 &&
                  bytes[pos] <= 0x37) {
                oct = oct * 8 + (bytes[pos] - 0x30);
                pos++;
                n++;
              }
              out.addByte(oct & 0xFF);
            } else {
              out.addByte(c);
              pos++;
            }
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) {
          pos++;
          return out.takeBytes();
        }
      }
      out.addByte(c);
      pos++;
    }
    throw const PdfSyntaxException('Unterminated literal string');
  }

  PdfObject _parseHexString() {
    pos++; // '<'
    final nibbles = <int>[];
    while (pos < bytes.length && bytes[pos] != 0x3E) {
      final c = bytes[pos];
      if (!isWhitespace(c)) nibbles.add(c);
      pos++;
    }
    pos++; // '>'
    if (nibbles.length.isOdd) nibbles.add(0x30);
    int hexVal(int c) {
      if (c >= 0x30 && c <= 0x39) return c - 0x30;
      if (c >= 0x41 && c <= 0x46) return c - 0x37;
      if (c >= 0x61 && c <= 0x66) return c - 0x57;
      throw const PdfSyntaxException('Invalid hex string character');
    }

    final out = Uint8List(nibbles.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = hexVal(nibbles[i * 2]) * 16 + hexVal(nibbles[i * 2 + 1]);
    }
    return PdfString(out);
  }

  PdfObject _parseArray() {
    pos++; // '['
    final items = <PdfObject>[];
    while (true) {
      skipWhitespaceAndComments();
      if (pos >= bytes.length) {
        throw const PdfSyntaxException('Unterminated array');
      }
      if (bytes[pos] == 0x5D) {
        pos++;
        return PdfArray(items);
      }
      items.add(parseObject());
    }
  }

  PdfObject _parseDictOrStream() {
    pos += 2; // '<<'
    final map = <String, PdfObject>{};
    while (true) {
      skipWhitespaceAndComments();
      if (pos + 1 >= bytes.length) {
        throw const PdfSyntaxException('Unterminated dictionary');
      }
      if (bytes[pos] == 0x3E && bytes[pos + 1] == 0x3E) {
        pos += 2;
        break;
      }
      final keyObj = parseObject();
      if (keyObj is! PdfName) {
        throw const PdfSyntaxException('Dictionary key is not a name');
      }
      map[keyObj.name] = parseObject();
    }
    final dict = PdfDictionary(map);
    final saved = pos;
    skipWhitespaceAndComments();
    if (matchKeyword('stream')) {
      if (pos < bytes.length && bytes[pos] == 0x0D) pos++;
      if (pos < bytes.length && bytes[pos] == 0x0A) pos++;
      final dataStart = pos;
      int dataEnd;
      final length = dict['Length'];
      if (length is PdfNumber &&
          length.intValue >= 0 &&
          dataStart + length.intValue <= bytes.length) {
        dataEnd = dataStart + length.intValue;
      } else {
        // /Length is indirect or bogus: locate 'endstream' and strip one EOL.
        dataEnd = _findEndstream(dataStart);
      }
      pos = dataEnd;
      return PdfStream(dict, Uint8List.sublistView(bytes, dataStart, dataEnd));
    }
    pos = saved;
    return dict;
  }

  int _findEndstream(int from) {
    for (var i = from; i + 9 <= bytes.length; i++) {
      if (bytes[i] == 0x65 &&
          latin1.decode(bytes.sublist(i, i + 9)) == 'endstream') {
        var end = i;
        if (end > from && bytes[end - 1] == 0x0A) end--;
        if (end > from && bytes[end - 1] == 0x0D) end--;
        return end;
      }
    }
    throw const PdfSyntaxException('endstream keyword not found');
  }
}

/// Raised for malformed input. Subtype of [PdfExtractException] so callers
/// can catch the family with one type.
class PdfSyntaxException extends PdfExtractException {
  const PdfSyntaxException(super.message);
}

/// Base exception family for all PDF extraction failures. Messages are
/// English and machine-oriented; the UI layer maps typed subclasses to
/// localized strings.
class PdfExtractException implements Exception {
  final String message;
  const PdfExtractException(this.message);
  @override
  String toString() => message;
}
```

注意：`PdfSyntaxException extends PdfExtractException`，但 `PdfExtractException` 是 `implements Exception` 的普通类——子类声明顺序无关紧要（Dart 允许同文件任意顺序），但要保证两者在**同一个文件**中。

- [ ] **Step 2.4: 运行确认通过**

Run: `flutter test test/pdf_objects_test.dart`
Expected: PASS（11 个测试）

- [ ] **Step 2.5: 提交**

```bash
git add lib/utils/pdf/objects.dart test/pdf_objects_test.dart
git commit -m "feat: PDF object model and recursive-descent parser"
```

### Task 3: PdfDocument — startxref / 传统 xref / trailer / 对象获取（pdf/document.dart）

**Files:**
- Create: `lib/utils/pdf/document.dart`
- Create: `test/helpers/pdf_builder.dart`
- Test: `test/pdf_document_test.dart`

- [ ] **Step 3.1: 创建测试用迷你 PDF 写出器**

```dart
// test/helpers/pdf_builder.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal but structurally valid PDF writer for tests. Computes exact xref
/// offsets at build time so the parser under test sees real file structure.
///
/// Deliberately independent from lib/utils/pdf/ (no shared code with the
/// parser) and from lib/utils/pdf.dart (the app's export writer).
class TestPdfBuilder {
  final BytesBuilder _out = BytesBuilder();

  /// Object number -> byte offset. Index 0 is the mandatory free head.
  /// Null entries are gaps (objects living inside an object stream).
  final List<int?> _offsets = [0];

  /// Offset of the last xref section written (for building /Prev chains).
  int? lastXrefOffset;

  TestPdfBuilder() {
    _write('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n');
  }

  int get nextObjectNumber => _offsets.length;

  void _write(String s) => _out.add(latin1.encode(s));

  void _writeBytes(List<int> d) => _out.add(d);

  /// Appends `N 0 obj <body> endobj` with the next sequential number.
  int addObject(String body) {
    final n = nextObjectNumber;
    _offsets.add(_out.length);
    _write('$n 0 obj\n$body\nendobj\n');
    return n;
  }

  /// Appends a stream object; /Length is added automatically.
  int addStreamObject(String dictEntries, List<int> data,
      {bool omitLength = false}) {
    final n = nextObjectNumber;
    _offsets.add(_out.length);
    final length = omitLength ? '' : '/Length ${data.length} ';
    _write('$n 0 obj\n<< ${dictEntries.trim()} $length>>\nstream\n');
    _writeBytes(data);
    _write('\nendstream\nendobj\n');
    return n;
  }

  /// Appends an object with an explicit number (may leave gaps).
  void addObjectAt(int objNum, String body) {
    while (_offsets.length <= objNum) {
      _offsets.add(null);
    }
    _offsets[objNum] = _out.length;
    _write('$objNum 0 obj\n$body\nendobj\n');
  }

  /// Appends a stream object with an explicit number.
  void addStreamObjectAt(int objNum, String dictEntries, List<int> data) {
    while (_offsets.length <= objNum) {
      _offsets.add(null);
    }
    _offsets[objNum] = _out.length;
    _write('$objNum 0 obj\n<< ${dictEntries.trim()} /Length ${data.length} >>\n'
        'stream\n');
    _writeBytes(data);
    _write('\nendstream\nendobj\n');
  }

  /// Appends raw bytes verbatim (used to stack incremental updates).
  void appendRaw(String s) => _write(s);

  /// Finishes with a classic xref table + trailer.
  Uint8List finishClassic({required int rootObj, String extraTrailerEntries = ''}) {
    final xrefOffset = _out.length;
    lastXrefOffset = xrefOffset;
    final size = _offsets.length;
    _write('xref\n0 $size\n');
    _write('0000000000 65535 f\r\n');
    for (final off in _offsets.skip(1)) {
      _write('${(off ?? 0).toString().padLeft(10, '0')} 00000 n\r\n');
    }
    _write('trailer\n<< /Size $size /Root $rootObj 0 R '
        '$extraTrailerEntries>>\nstartxref\n$xrefOffset\n%%EOF\n');
    return _out.takeBytes();
  }

  /// Finishes with a PDF 1.5 cross-reference stream (W = [1 4 2]).
  ///
  /// [extraEntries] maps object number -> (type, field2, field3) and is used
  /// to declare type-2 (compressed) entries pointing into an object stream.
  Uint8List finishXrefStream({
    required int rootObj,
    Map<int, (int, int, int)> extraEntries = const {},
    String extraDictEntries = '',
  }) {
    final entries = <int, (int, int, int)>{0: (0, 0, 0xFFFF)};
    for (var n = 1; n < _offsets.length; n++) {
      final off = _offsets[n];
      if (off != null) entries[n] = (1, off, 0);
    }
    entries.addAll(extraEntries);
    var highest = 0;
    for (final k in entries.keys) {
      if (k > highest) highest = k;
    }
    final xrefObjNum = highest + 1;
    final size = xrefObjNum + 1;
    final selfOffset = _out.length;
    entries[xrefObjNum] = (1, selfOffset, 0);
    lastXrefOffset = selfOffset;

    final index = BytesBuilder();
    for (var n = 0; n < size; n++) {
      final e = entries[n] ?? (0, 0, 0);
      index.addByte(e.$1);
      index.add([
        (e.$2 >> 24) & 0xFF,
        (e.$2 >> 16) & 0xFF,
        (e.$2 >> 8) & 0xFF,
        e.$2 & 0xFF,
      ]);
      index.add([(e.$3 >> 8) & 0xFF, e.$3 & 0xFF]);
    }
    final compressed =
        Uint8List.fromList(ZLibEncoder().convert(index.takeBytes()));
    _write('$xrefObjNum 0 obj\n<< /Type /XRef /Size $size /W [1 4 2] '
        '/Index [0 $size] /Filter /FlateDecode /Root $rootObj 0 R '
        '/Length ${compressed.length} $extraDictEntries>>\nstream\n');
    _writeBytes(compressed);
    _write('\nendstream\nendobj\nstartxref\n$selfOffset\n%%EOF\n');
    return _out.takeBytes();
  }
}

/// One page of [buildImagePdf]: a single image XObject with pre-encoded
/// stream bytes.
class TestPdfPage {
  TestPdfPage({
    required this.width,
    required this.height,
    required this.data,
    this.filter = 'FlateDecode',
    this.colorSpace = 'DeviceRGB',
    this.bpc = 8,
    this.extraDict = '',
  });

  final int width;
  final int height;

  /// Stream bytes with [filter] already applied (e.g. zlib-compressed RGB).
  final Uint8List data;
  final String filter;
  final String colorSpace;
  final int bpc;

  /// Extra image-dict entries, e.g. '/DecodeParms << /Predictor 12 >>'.
  final String extraDict;
}

/// Builds a PDF with one image page per entry in [pages].
Uint8List buildImagePdf(List<TestPdfPage> pages, {bool xrefStream = false}) {
  final b = TestPdfBuilder();
  b.addObject('<< /Type /Catalog /Pages 2 0 R >>'); // obj 1
  final pageObjs = [for (var i = 0; i < pages.length; i++) 3 + 2 * i];
  b.addObject('<< /Type /Pages /Kids [${pageObjs.map((o) => '$o 0 R').join(' ')}] '
      '/Count ${pages.length} >>'); // obj 2
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    final imageObj = 4 + 2 * i;
    b.addObject('<< /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${p.width} ${p.height}] '
        '/Resources << /XObject << /Im0 $imageObj 0 R >> >> >>');
    b.addStreamObject(
      '/Type /XObject /Subtype /Image /Width ${p.width} /Height ${p.height} '
      '/ColorSpace ${p.colorSpace} /BitsPerComponent ${p.bpc} '
      '/Filter /${p.filter} ${p.extraDict}',
      p.data,
    );
  }
  return xrefStream
      ? b.finishXrefStream(rootObj: 1)
      : b.finishClassic(rootObj: 1);
}

Uint8List flate(Uint8List raw) =>
    Uint8List.fromList(ZLibEncoder().convert(raw));
```

- [ ] **Step 3.2: 写失败测试**

```dart
// test/pdf_document_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/document.dart';
import 'package:venera/utils/pdf/objects.dart';

import 'helpers/pdf_builder.dart';

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
          'startxref\n${tail.length + 0}\n%%EOF\n';
      // The startxref value must point at the new xref keyword; compute it.
      final updateBytes = latin1.encode(update);
      final xrefPos = newOffset +
          update.indexOf('xref\n0 2');
      final fixedUpdate = update.replaceFirst(
          'startxref\n${tail.length + 0}', 'startxref\n$xrefPos');
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
}
```

注意最后一个测试：`open()` 是 async，`expect(() => doc.open(), throwsA(...))` 对返回 Future 的函数同样有效（flutter_test 支持 matcher 匹配 Future 错误）；如报错请改用 `expectLater(doc.open(), throwsA(...))`。

- [ ] **Step 3.3: 运行确认失败**

Run: `flutter test test/pdf_document_test.dart`
Expected: FAIL（document.dart 不存在）

- [ ] **Step 3.4: 实现 document.dart**

```dart
// lib/utils/pdf/document.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'objects.dart';

class _XrefEntry {
  /// 1 = uncompressed (field2 = byte offset, field3 = generation),
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
  final Map<int, ({List<int> nums, List<PdfObject?> objects})> _objStmCache = {};

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
    p.skipWhitespaceAndComments();
    p.parseObject(); // object number
    p.parseObject(); // generation
    p.matchKeyword('obj');
    final obj = p.parseObject();
    if (obj is! PdfStream ||
        (obj.dict['Type'] as PdfName?)?.name != 'XRef') {
      throw PdfSyntaxException('No xref at offset $offset');
    }
    _readXrefStream(obj); // Task 4
    final prev = (obj.dict['Prev'] as PdfNumber?)?.intValue ?? 0;
    return (trailer: obj.dict, prev: prev);
  }

  ({PdfDictionary trailer, int prev}) _parseClassicXref(PdfParser p) {
    while (true) {
      p.skipWhitespaceAndComments();
      if (p.matchKeyword('trailer')) break;
      final firstObj = (p.parseObject() as PdfNumber).intValue;
      final count = (p.parseObject() as PdfNumber).intValue;
      for (var i = 0; i < count; i++) {
        // Entries are nominally 20 bytes but producers vary the EOL; reading
        // three whitespace-delimited tokens per entry tolerates all variants.
        final offText = p.readToken();
        final genText = p.readToken();
        final typeText = p.readToken();
        final objNum = firstObj + i;
        if (_xref.containsKey(objNum)) continue; // newest section wins
        if (typeText == 'n') {
          _xref[objNum] =
              _XrefEntry(1, int.parse(offText), int.parse(genText));
        }
      }
    }
    final trailerObj = p.parseObject();
    if (trailerObj is! PdfDictionary) {
      throw const PdfSyntaxException('Malformed trailer');
    }
    final prev = (trailerObj['Prev'] as PdfNumber?)?.intValue ?? 0;
    return (trailer: trailerObj, prev: prev);
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
      final p = PdfParser(bytes, entry.field2);
      p.skipWhitespaceAndComments();
      p.parseObject(); // object number
      p.parseObject(); // generation
      p.matchKeyword('obj');
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
```

同时给 `objects.dart` 末尾追加（供 document.dart 签名使用，Task 8 才真正接线）：

```dart
/// Called when an encrypted PDF needs a user password. The returned string
/// is tried; returning null means the user cancelled.
typedef PdfPasswordProvider = Future<String?> Function(String fileName);
```

- [ ] **Step 3.5: 运行确认通过**

Run: `flutter test test/pdf_document_test.dart`
Expected: PASS（6 个测试）

- [ ] **Step 3.6: 提交**

```bash
git add lib/utils/pdf/document.dart lib/utils/pdf/objects.dart test/helpers/pdf_builder.dart test/pdf_document_test.dart
git commit -m "feat: PDF document structure - startxref, classic xref, object fetch"
```

---

### Task 4: xref 流 + 对象流（ObjStm）

**Files:**
- Modify: `lib/utils/pdf/document.dart`（替换 `_readXrefStream` 占位、扩展 `fetch` 支持 type-2、`_parseXrefAt` 中 xref 流永不解密注释）
- Test: `test/pdf_document_test.dart`（追加 group）

- [ ] **Step 4.1: 追加失败测试**

在 `test/pdf_document_test.dart` 的 main() 内追加：

```dart
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
      final inner = latin1.encode('$header<< /Type /Pages /Kids [4 0 R] /Count 1 >>');
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
  });
```

- [ ] **Step 4.2: 运行确认失败**

Run: `flutter test test/pdf_document_test.dart`
Expected: FAIL（"Cross-reference streams not supported yet"）

- [ ] **Step 4.3: 实现**

替换 `document.dart` 中的 `_readXrefStream` 占位：

```dart
  /// Reads a PDF 1.5+ cross-reference stream. Per spec 7.5.8.2 xref streams
  /// are never encrypted, so this runs before security setup.
  void _readXrefStream(PdfStream stream) {
    var data = stream.raw;
    final len = stream.dict['Length'];
    if (len is PdfNumber && len.intValue >= 0 && len.intValue <= data.length) {
      data = Uint8List.sublistView(data, 0, len.intValue);
    }
    final filter = stream.dict['Filter'];
    if (filter is PdfName && filter.name == 'FlateDecode') {
      data = inflatePdf(data);
    } else if (filter != null) {
      throw const PdfSyntaxException('Unsupported xref stream filter');
    }
    final w = (stream.dict['W'] as PdfArray?)
            ?.items
            .map((e) => (e as PdfNumber).intValue)
            .toList() ??
        (throw const PdfSyntaxException('xref stream without /W'));
    final size = (stream.dict['Size'] as PdfNumber?)?.intValue ?? 0;
    List<int> index;
    final indexObj = stream.dict['Index'];
    if (indexObj is PdfArray) {
      index = indexObj.items.map((e) => (e as PdfNumber).intValue).toList();
    } else {
      index = [0, size];
    }
    final entrySize = w[0] + w[1] + w[2];
    if (entrySize == 0) {
      throw const PdfSyntaxException('Degenerate xref stream /W');
    }
    var cursor = 0;
    int readField(int wi) {
      if (w[wi] == 0) {
        // Spec defaults: type 1, fields 0.
        return wi == 0 ? 1 : 0;
      }
      var v = 0;
      for (var k = 0; k < w[wi]; k++) {
        if (cursor >= data.length) {
          throw const PdfSyntaxException('Truncated xref stream');
        }
        v = (v << 8) | data[cursor];
        cursor++;
      }
      return v;
    }

    for (var s = 0; s + 1 < index.length; s += 2) {
      final first = index[s];
      final count = index[s + 1];
      for (var i = 0; i < count; i++) {
        final type = readField(0);
        final f2 = readField(1);
        final f3 = readField(2);
        final objNum = first + i;
        if (_xref.containsKey(objNum)) continue; // newest section wins
        if (type == 1 || type == 2) {
          _xref[objNum] = _XrefEntry(type, f2, f3);
        }
        // type 0 = free: not recorded
      }
    }
  }
```

扩展 `fetch()` 支持 type-2（在 `if (entry != null && entry.type == 1) {...}` 之后加 else 分支）：

```dart
    } else if (entry != null && entry.type == 2) {
      obj = _fetchFromObjStm(entry.field2, entry.field3);
    }
```

并新增：

```dart
  /// Extracts one object from a compressed object stream (cached per stream).
  PdfObject? _fetchFromObjStm(int stmNum, int index) {
    var cached = _objStmCache[stmNum];
    if (cached == null) {
      final stm = fetch(stmNum);
      if (stm is! PdfStream) {
        throw PdfSyntaxException('Object stream $stmNum is not a stream');
      }
      final data = inflatePdf(streamData(stm));
      final n = (stm.dict['N'] as PdfNumber?)?.intValue ?? 0;
      final first = (stm.dict['First'] as PdfNumber?)?.intValue ?? 0;
      final header = PdfParser(data, 0);
      final nums = <int>[];
      final offs = <int>[];
      for (var i = 0; i < n; i++) {
        nums.add((header.parseObject() as PdfNumber).intValue);
        offs.add((header.parseObject() as PdfNumber).intValue);
      }
      final objects = List<PdfObject?>.filled(n, null);
      for (var i = 0; i < n; i++) {
        final p = PdfParser(data, first + offs[i]);
        objects[i] = p.parseObject();
      }
      cached = (nums: nums, objects: objects);
      _objStmCache[stmNum] = cached;
    }
    if (index < 0 || index >= cached.objects.length) {
      throw PdfSyntaxException('Index $index out of range in ObjStm $stmNum');
    }
    return cached.objects[index];
  }
```

在 `document.dart` 顶部（或底部）新增 zlib 帮助函数（Task 6 的解码管线也会复用，因此放 document.dart 并公开）：

```dart
/// Inflates a PDF FlateDecode payload. Tolerates producers that omit the
/// zlib header (raw deflate).
Uint8List inflatePdf(Uint8List data) {
  try {
    return Uint8List.fromList(zlib.decode(data));
  } on FormatException {
    return Uint8List.fromList(const ZLibDecoder(raw: true).convert(data));
  }
}
```

- [ ] **Step 4.4: 运行确认通过**

Run: `flutter test test/pdf_document_test.dart`
Expected: PASS（8 个测试）

- [ ] **Step 4.5: 提交**

```bash
git add lib/utils/pdf/document.dart test/pdf_document_test.dart
git commit -m "feat: PDF 1.5 cross-reference streams and object streams"
```

---

### Task 5: 页树遍历 + 资源继承 + 图片收集

**Files:**
- Modify: `lib/utils/pdf/document.dart`（新增 `pages()`）
- Test: `test/pdf_document_test.dart`（追加 group）

- [ ] **Step 5.1: 追加失败测试**

```dart
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
      for (final obj in [3, 4]) {
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
```

注意第三个测试里对象编号：obj3、obj4 是两次 addStreamObject（顺序 3、4），页对象是 5。`Kids [5 0 R]` 与写入顺序无关（引用按编号解析）✓。

- [ ] **Step 5.2: 运行确认失败**

Run: `flutter test test/pdf_document_test.dart`
Expected: FAIL（`pages` / `collectPageImageStreams` 未定义）

- [ ] **Step 5.3: 实现**

在 `document.dart` 的 `PdfDocument` 类中新增：

```dart
  /// Leaf pages in reading order, each paired with its effective /Resources
  /// (page-level value wins; otherwise inherited from ancestor Pages nodes,
  /// per spec 7.7.3.3).
  List<({PdfDictionary page, PdfObject? resources})> pages() {
    final root = resolveDict(trailer['Root']);
    final pagesRoot = resolveDict(root['Pages']);
    final result = <({PdfDictionary page, PdfObject? resources})>[];
    void walk(PdfDictionary node, PdfObject? inheritedResources, int depth) {
      if (depth > 64) {
        throw const PdfSyntaxException('Page tree too deep (cycle?)');
      }
      final resources = node['Resources'] ?? inheritedResources;
      final type = (resolve(node['Type']) as PdfName?)?.name;
      final kids = resolve(node['Kids']);
      if (type == 'Page' || kids is! PdfArray) {
        result.add((page: node, resources: resources));
        return;
      }
      for (final k in kids.items) {
        final child = resolve(k);
        if (child is PdfDictionary) {
          walk(child, resources, depth + 1);
        }
      }
    }

    walk(pagesRoot, null, 0);
    return result;
  }

  /// Image XObject streams of one page, ordered by resource name (design
  /// decision: content-stream `Do` order is not parsed; see spec §11).
  List<PdfStream> collectPageImageStreams(
      ({PdfDictionary page, PdfObject? resources}) entry) {
    final resources = resolve(entry.resources);
    if (resources is! PdfDictionary) return const [];
    final xobjects = resolve(resources['XObject']);
    if (xobjects is! PdfDictionary) return const [];
    final names = xobjects.map.keys.toList()..sort();
    final result = <PdfStream>[];
    for (final name in names) {
      final obj = resolve(xobjects[name]);
      if (obj is PdfStream &&
          (resolve(obj.dict['Subtype']) as PdfName?)?.name == 'Image') {
        result.add(obj);
      }
    }
    return result;
  }
```

- [ ] **Step 5.4: 运行确认通过**

Run: `flutter test test/pdf_document_test.dart`
Expected: PASS（11 个测试）

- [ ] **Step 5.5: 提交**

```bash
git add lib/utils/pdf/document.dart test/pdf_document_test.dart
git commit -m "feat: PDF page tree walk with resource inheritance and image collection"
```

---

### Task 6: 图片解码管线 + extractPdfImages（未加密文档全链路）

**Files:**
- Create: `lib/utils/pdf/images.dart`
- Test: `test/pdf_images_test.dart`

- [ ] **Step 6.1: 写失败测试**

```dart
// test/pdf_images_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/images.dart';

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
      expect(await decodePngPixels(images[0].bytes),
          [255, 0, 0, 0, 0, 255]);
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
      final fakeJpeg = Uint8List.fromList(
          [0xFF, 0xD8, 1, 2, 3, 4, 5, 0xFF, 0xD9]);
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
      expect(await decodePngPixels(images.single.bytes),
          [255, 0, 0, 0, 0, 255]);
    });

    test('a document without images throws PdfNoImagesException', () async {
      final b = TestPdfBuilder();
      b.addObject('<< /Type /Catalog /Pages 2 0 R >>');
      b.addObject('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
      b.addObject('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>');
      final pdf = b.finishClassic(rootObj: 1);
      expect(
        () => extractPdfImages(pdf).toList(),
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
      final cmyk = Uint8List.fromList([0, 0, 0, 0]); // C=M=Y=K=0 → white
      final rgb = toRgb8(cmyk, 'DeviceCMYK', 1, 1);
      expect(rgb, [255, 255, 255]);
    });

    test('16-bit samples downsample to 8-bit by rounding', () {
      final samples = Uint8List.fromList([0xFF, 0xFF, 0x00, 0x00]); // gray 16b
      final rgb = toRgb8(samples, 'DeviceGray', 1, 1, bpc: 16);
      expect(rgb, [255, 255, 255]);
    });
  });
}
```

- [ ] **Step 6.2: 运行确认失败**

Run: `flutter test test/pdf_images_test.dart`
Expected: FAIL（images.dart 不存在）

- [ ] **Step 6.3: 实现 images.dart**

```dart
// lib/utils/pdf/images.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'document.dart';
import 'objects.dart';
import 'png_encoder.dart';

/// An image extracted from one PDF page.
class PdfImage {
  /// 0-based page index.
  final int pageIndex;

  /// File extension without dot: 'jpg' (DCTDecode passthrough) or 'png'.
  final String extension;

  final Uint8List bytes;

  const PdfImage(this.pageIndex, this.extension, this.bytes);
}

class PdfNoImagesException extends PdfExtractException {
  PdfNoImagesException() : super('No images found in the PDF');
}

/// Thrown for image encodings this extractor intentionally does not support
/// (JPXDecode/CCITTFaxDecode/JBIG2Decode, unusual bit depths, ...).
class PdfUnsupportedEncodingException extends PdfExtractException {
  /// 1-based page number, for user-facing messages.
  final int page;
  final String filter;
  PdfUnsupportedEncodingException(this.page, this.filter)
      : super('Unsupported image encoding "$filter" on page $page');
}

/// Extracts every page image from an image-based comic PDF.
///
/// Yields images in page order (multiple images within a page sorted by
/// resource name). Throws [PdfNoImagesException] when nothing was found.
/// [passwordProvider] is wired up in Task 8 (encrypted documents).
Stream<PdfImage> extractPdfImages(
  Uint8List data, {
  PdfPasswordProvider? passwordProvider,
  String fileName = '',
}) async* {
  final doc = PdfDocument(data);
  await doc.open(passwordProvider: passwordProvider, fileName: fileName);
  var pageIndex = 0;
  var emitted = 0;
  for (final entry in doc.pages()) {
    for (final stream in doc.collectPageImageStreams(entry)) {
      final image = decodeImageStream(doc, stream, pageIndex + 1);
      if (image != null) {
        yield image;
        emitted++;
      }
    }
    pageIndex++;
    // Keep the UI responsive during large imports.
    await null;
  }
  if (emitted == 0) {
    throw PdfNoImagesException();
  }
}

/// Decodes one image XObject. Returns null for stencil masks (/ImageMask),
/// which are not comic content.
PdfImage? decodeImageStream(PdfDocument doc, PdfStream stream, int humanPage) {
  final dict = stream.dict;
  if (_boolOf(doc, dict['ImageMask'])) {
    return null;
  }
  var data = doc.streamData(stream);

  // Apply /Filter chain: Flate decodes in place; DCT must be the last
  // filter, in which case the bytes are a JPEG and pass through untouched.
  final filters = <String>[];
  final f = doc.resolve(dict['Filter']);
  if (f is PdfName) {
    filters.add(f.name);
  } else if (f is PdfArray) {
    for (final e in f.items) {
      final n = doc.resolve(e);
      if (n is PdfName) filters.add(n.name);
    }
  }
  PdfObject? flateParms;
  for (var i = 0; i < filters.length; i++) {
    switch (filters[i]) {
      case 'FlateDecode':
        data = inflatePdf(data);
        final parms = doc.resolve(dict['DecodeParms'] ?? dict['DecodeParams']);
        flateParms = parms is PdfArray
            ? (i < parms.items.length ? parms.items[i] : null)
            : parms;
      case 'DCTDecode':
        if (i != filters.length - 1) {
          throw PdfUnsupportedEncodingException(humanPage, filters[i]);
        }
        return PdfImage(humanPage - 1, 'jpg', data);
      default:
        throw PdfUnsupportedEncodingException(humanPage, filters[i]);
    }
  }

  final width = (doc.resolve(dict['Width']) as PdfNumber?)?.intValue;
  final height = (doc.resolve(dict['Height']) as PdfNumber?)?.intValue;
  if (width == null || height == null || width <= 0 || height <= 0) {
    throw PdfExtractException('Page $humanPage: image without valid dimensions');
  }
  var bpc = (doc.resolve(dict['BitsPerComponent']) as PdfNumber?)?.intValue ?? 8;

  // Resolve the color space to a device space name, expanding /Indexed and
  // mapping /ICCBased by component count.
  var samples = data;
  var csName = 'DeviceRGB';
  var csObj = doc.resolve(dict['ColorSpace']);
  if (csObj is PdfArray && csObj.items.isNotEmpty) {
    final family = (doc.resolve(csObj.items[0]) as PdfName?)?.name;
    if (family == 'Indexed') {
      final base = doc.resolve(csObj.items[1]);
      final lookup = doc.resolve(csObj.items[3]);
      Uint8List table;
      if (lookup is PdfString) {
        table = lookup.bytes;
      } else if (lookup is PdfStream) {
        table = inflateIfFlate(doc, lookup);
      } else {
        throw PdfExtractException('Page $humanPage: bad /Indexed lookup');
      }
      final baseName = deviceNameFor(doc, base, humanPage);
      final baseChannels = channelsFor(baseName);
      samples = expandIndexed(samples, table, baseChannels);
      csName = baseName;
      bpc = 8; // lookup table entries are base-space samples at table bpc;
               // comic PDFs use 8-bit bases (hival <= 255).
    } else if (family == 'ICCBased') {
      csName = deviceNameFor(doc, csObj, humanPage);
    } else {
      throw PdfUnsupportedEncodingException(humanPage, 'ColorSpace $family');
    }
  } else if (csObj is PdfName) {
    csName = csObj.name;
  }

  // Predictor (from FlateDecode's DecodeParms).
  if (flateParms is PdfDictionary) {
    final predictor =
        (flateParms['Predictor'] as PdfNumber?)?.intValue ?? 1;
    final colors =
        (flateParms['Colors'] as PdfNumber?)?.intValue ?? channelsFor(csName);
    final parmsBpc =
        (flateParms['BitsPerComponent'] as PdfNumber?)?.intValue ?? bpc;
    final columns =
        (flateParms['Columns'] as PdfNumber?)?.intValue ?? width;
    samples = applyPredictorInverse(samples,
        predictor: predictor, columns: columns, colors: colors, bpc: parmsBpc);
  }

  final decode = (doc.resolve(dict['Decode']) as PdfArray?)?.items
      .map((e) => (doc.resolve(e) as PdfNumber).value)
      .toList();

  final rgb = toRgb8(samples, csName, width, height, decode: decode, bpc: bpc);
  return PdfImage(
    humanPage - 1,
    'png',
    encodePng(width: width, height: height, channels: 3, samples: rgb),
  );
}

bool _boolOf(PdfDocument doc, PdfObject? obj) =>
    (doc.resolve(obj) as PdfBool?)?.value ?? false;

Uint8List inflateIfFlate(PdfDocument doc, PdfStream stream) {
  var data = doc.streamData(stream);
  final filter = doc.resolve(stream.dict['Filter']);
  if (filter is PdfName && filter.name == 'FlateDecode') {
    data = inflatePdf(data);
  }
  return data;
}

/// Maps a color-space object (name or [/ICCBased dict]) to a device space
/// name we can convert from.
String deviceNameFor(PdfDocument doc, PdfObject? cs, int humanPage) {
  final resolved = doc.resolve(cs);
  if (resolved is PdfName) {
    return resolved.name;
  }
  if (resolved is PdfArray && resolved.items.isNotEmpty) {
    final family = (doc.resolve(resolved.items[0]) as PdfName?)?.name;
    if (family == 'ICCBased') {
      final icc = doc.resolveDict(resolved.items[1]);
      final n = (icc['N'] as PdfNumber?)?.intValue ?? 3;
      return switch (n) {
        1 => 'DeviceGray',
        3 => 'DeviceRGB',
        4 => 'DeviceCMYK',
        _ => throw PdfUnsupportedEncodingException(humanPage, 'ICCBased N=$n'),
      };
    }
  }
  throw PdfUnsupportedEncodingException(humanPage, 'ColorSpace');
}

int channelsFor(String deviceName) => switch (deviceName) {
      'DeviceGray' => 1,
      'DeviceRGB' => 3,
      'DeviceCMYK' => 4,
      _ => 3,
    };

/// Expands indexed samples (1 byte per pixel index) through [table].
Uint8List expandIndexed(Uint8List indices, Uint8List table, int baseChannels) {
  final out = Uint8List(indices.length * baseChannels);
  for (var i = 0; i < indices.length; i++) {
    final base = indices[i] * baseChannels;
    for (var c = 0; c < baseChannels; c++) {
      out[i * baseChannels + c] =
          base + c < table.length ? table[base + c] : 0;
    }
  }
  return out;
}

/// Inverts PNG (10-15) or TIFF (2) predictors in place-safe fashion and
/// returns the reconstructed sample bytes. Predictor 1 returns [data].
Uint8List applyPredictorInverse(
  Uint8List data, {
  required int predictor,
  required int columns,
  required int colors,
  required int bpc,
}) {
  if (predictor == 1) return data;
  final compBytes = math.max(1, bpc ~/ 8);
  final bpp = math.max(1, colors * compBytes);
  final rowBytes = math.max(1, (columns * colors * bpc + 7) ~/ 8);

  if (predictor == 2) {
    // TIFF predictor: horizontal accumulation per component.
    final out = Uint8List.fromList(data);
    for (var row = 0; row + rowBytes <= out.length; row += rowBytes) {
      for (var i = bpp; i < rowBytes; i += compBytes) {
        if (compBytes == 1) {
          out[row + i] = (out[row + i] + out[row + i - bpp]) & 0xFF;
        } else {
          final cur = (out[row + i] << 8) | out[row + i + 1];
          final left = (out[row + i - bpp] << 8) | out[row + i - bpp + 1];
          final sum = (cur + left) & 0xFFFF;
          out[row + i] = (sum >> 8) & 0xFF;
          out[row + i + 1] = sum & 0xFF;
        }
      }
    }
    return out;
  }

  if (predictor >= 10 && predictor <= 15) {
    final rows = data.length ~/ (rowBytes + 1);
    final out = Uint8List(rows * rowBytes);
    final prev = Uint8List(rowBytes);
    for (var y = 0; y < rows; y++) {
      final filter = data[y * (rowBytes + 1)];
      final lineStart = y * (rowBytes + 1) + 1;
      final outStart = y * rowBytes;
      for (var x = 0; x < rowBytes; x++) {
        final cur = data[lineStart + x];
        final left = x >= bpp ? out[outStart + x - bpp] : 0;
        final up = prev[x];
        final upLeft = x >= bpp ? prev[x - bpp] : 0;
        final v = switch (filter) {
          0 => cur,
          1 => cur + left,
          2 => cur + up,
          3 => cur + ((left + up) >> 1),
          4 => cur + _paeth(left, up, upLeft),
          _ => cur,
        };
        out[outStart + x] = v & 0xFF;
      }
      prev.setRange(0, rowBytes, out, outStart);
    }
    return out;
  }

  throw PdfExtractException('Unsupported predictor $predictor');
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Converts samples in [csName] device space to 8-bit RGB.
///
/// [bpc] 8 or 16 (16 is downsampled with rounding). [decode] is the image
/// dict's /Decode array; `[1 0 ...]` marks Adobe-inverted CMYK.
Uint8List toRgb8(
  Uint8List samples,
  String csName,
  int width,
  int height, {
  List<double>? decode,
  int bpc = 8,
}) {
  if (bpc != 8 && bpc != 16) {
    throw PdfExtractException('Unsupported BitsPerComponent $bpc');
  }
  final channels = channelsFor(csName);
  final px = width * height;
  if (samples.length < px * channels * (bpc ~/ 8)) {
    throw const PdfExtractException('Truncated image sample data');
  }
  int sampleAt(int i) {
    if (bpc == 8) return samples[i];
    return ((samples[i * 2] << 8 | samples[i * 2 + 1]) * 255 / 65535).round();
  }

  final out = Uint8List(px * 3);
  switch (csName) {
    case 'DeviceGray':
      for (var i = 0; i < px; i++) {
        final g = sampleAt(i);
        out[i * 3] = g;
        out[i * 3 + 1] = g;
        out[i * 3 + 2] = g;
      }
    case 'DeviceRGB':
      for (var i = 0; i < px * 3; i++) {
        out[i] = bpc == 8 ? samples[i] : sampleAt(i);
      }
    case 'DeviceCMYK':
      final inverted =
          decode != null && decode.length >= 8 && decode[0] == 1.0;
      for (var i = 0; i < px; i++) {
        final c = sampleAt(i * 4);
        final m = sampleAt(i * 4 + 1);
        final y = sampleAt(i * 4 + 2);
        final k = sampleAt(i * 4 + 3);
        if (inverted) {
          // Adobe convention: stored values are already inverted.
          out[i * 3] = (c * k) ~/ 255;
          out[i * 3 + 1] = (m * k) ~/ 255;
          out[i * 3 + 2] = (y * k) ~/ 255;
        } else {
          out[i * 3] = ((255 - c) * (255 - k)) ~/ 255;
          out[i * 3 + 1] = ((255 - m) * (255 - k)) ~/ 255;
          out[i * 3 + 2] = ((255 - y) * (255 - k)) ~/ 255;
        }
      }
    default:
      throw PdfExtractException('Unsupported color space $csName');
  }
  return out;
}
```

- [ ] **Step 6.4: 运行确认通过**

Run: `flutter test test/pdf_images_test.dart`
Expected: PASS（13 个测试）

- [ ] **Step 6.5: 全量回归 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿
```bash
git add lib/utils/pdf/images.dart test/pdf_images_test.dart
git commit -m "feat: PDF image decode pipeline with JPEG passthrough and PNG conversion"
```

---
### Task 7: 测试 fixtures（加密/未加密 PDF）+ 离线生成脚本

**Files:**
- Create: `test/fixtures/pdf/generate_fixtures.py`
- Create（脚本生成后提交二进制）: `test/fixtures/pdf/plain_jpeg.pdf`、`enc_rc4_128.pdf`、`enc_aes128.pdf`、`enc_aes256_r6.pdf`、`owner_only.pdf`
- Test: `test/pdf_fixtures_test.dart`

fixtures 是 Task 8/9/10/12 的输入。生成需要一次 Python 环境；产物 `.pdf` 提交进仓库，测试运行时**不依赖 Python**。本任务的冒烟测试只打开未加密的 `plain_jpeg.pdf`（加密件在 Task 8/9 才可解析），其余仅校验存在性与 `%PDF` 头。

- [ ] **Step 7.1: 写失败测试**

```dart
// test/pdf_fixtures_test.dart
import 'dart:io';

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
```

- [ ] **Step 7.2: 运行确认失败**

Run: `flutter test test/pdf_fixtures_test.dart`
Expected: FAIL（`test/fixtures/pdf/*.pdf` 不存在，读取抛 FileSystemException）

- [ ] **Step 7.3: 写生成脚本**

```python
#!/usr/bin/env python3
# test/fixtures/pdf/generate_fixtures.py
"""Offline generator for the PDF-import test fixtures.

Run once from the repo root; the produced .pdf files are committed so the
Dart tests never need Python at runtime.

    pip install pillow img2pdf pypdf pikepdf
    python test/fixtures/pdf/generate_fixtures.py

Fixtures (all are a 2-page image PDF, one red page + one blue page):
  plain_jpeg.pdf     - JPEG (DCTDecode) passthrough, no encryption
  enc_rc4_128.pdf    - RC4-128 (V2/R3), user password "user123"
  enc_aes128.pdf     - AES-128 (V4/R4),  user password "user123"
  enc_aes256_r6.pdf  - AES-256 (V5/R6),  user password "user123"
  owner_only.pdf     - RC4-128, owner password "owner", EMPTY user password
                       (must open silently without prompting)
"""
import io
import os

import img2pdf
import pikepdf
import pypdf
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
USER_PW = "user123"


def _page_jpeg(color, size=(8, 8)):
    img = Image.new("RGB", size, color)
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


def _base_pdf_bytes():
    # img2pdf embeds each JPEG as a DCTDecode image XObject without re-encoding.
    pages = [_page_jpeg((255, 0, 0)), _page_jpeg((0, 0, 255))]
    return img2pdf.convert([io.BytesIO(p) for p in pages])


def _write(name, data):
    path = os.path.join(HERE, name)
    with open(path, "wb") as f:
        f.write(data)
    print("wrote", name, len(data), "bytes")


def _pypdf_encrypt(base, user_pw, owner_pw=None, algorithm="RC4-128"):
    w = pypdf.PdfWriter()
    w.append(io.BytesIO(base))
    w.encrypt(user_password=user_pw, owner_password=owner_pw, algorithm=algorithm)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def main():
    base = _base_pdf_bytes()
    _write("plain_jpeg.pdf", base)
    _write("enc_rc4_128.pdf", _pypdf_encrypt(base, USER_PW, algorithm="RC4-128"))
    _write("enc_aes128.pdf", _pypdf_encrypt(base, USER_PW, algorithm="AES-128"))
    _write("owner_only.pdf", _pypdf_encrypt(base, "", owner_pw="owner"))

    r6_path = os.path.join(HERE, "enc_aes256_r6.pdf")
    with pikepdf.open(io.BytesIO(base)) as pdf:
        pdf.save(r6_path, encryption=pikepdf.Encryption(owner="owner", user=USER_PW, R=6))
    print("wrote", "enc_aes256_r6.pdf")


if __name__ == "__main__":
    main()
```

- [ ] **Step 7.4: 生成 fixtures**

Run（仓库根目录）:
```bash
python -m pip install --quiet pillow img2pdf pypdf pikepdf
python test/fixtures/pdf/generate_fixtures.py
```
Expected: 打印 5 行 `wrote ...`，`test/fixtures/pdf/` 下出现 5 个 `.pdf`。
若某依赖装不上（例如离线环境），可临时只生成 `plain_jpeg.pdf`（仅需 `pillow`+`img2pdf`），其余加密件在 Task 8/9 前补齐；但**提交前必须 5 个齐全**，否则 Task 8/9/10 的测试无法运行。

- [ ] **Step 7.5: 运行确认通过**

Run: `flutter test test/pdf_fixtures_test.dart`
Expected: PASS（6 个测试：5 个存在性 + 1 个 plain_jpeg 提取）

- [ ] **Step 7.6: 提交**

```bash
git add test/fixtures/pdf/generate_fixtures.py test/fixtures/pdf/*.pdf test/pdf_fixtures_test.dart
git commit -m "test: add PDF import fixtures and offline generator script"
```

---

### Task 8: 标准安全处理器 R2-R4（RC4 / AES-128）+ 文档解密接线

**Files:**
- Create: `lib/utils/pdf/security.dart`
- Modify: `lib/utils/pdf/objects.dart`（追加 `PdfCancelledException`、`PdfEncryptedException`）
- Modify: `lib/utils/pdf/document.dart`（`security` 字段定型、`open()` 接线、`streamData()` 解密）
- Test: `test/pdf_security_test.dart`

**密码学要点（实现者按此逐条落地）：**
- Algorithm 2（文件密钥）：`MD5(pad32(pw) ‖ O ‖ P(4字节小端) ‖ ID[0] [‖ 0xFFFFFFFF 若 R≥4 且 /EncryptMetadata false])`；R≥3 再对前 `keyLen` 字节做 50 轮 MD5；`keyLen = /Length/8`（R2 默认 40 位=5 字节，R3+ 默认 128 位=16 字节）。
- Algorithm 4（R2 校验 U）：`U == RC4(key, 32字节padding)`。
- Algorithm 5（R3/R4 校验 U）：`h = MD5(padding32 ‖ ID[0])`；`t = RC4(key, h)`；再 19 轮 `t = RC4(key每字节异或i, t)`（i=1..19）；比对 `t == U[0:16]`。
- Algorithm 1（每对象密钥）：`MD5(key ‖ objNum(3字节小端) ‖ objGen(2字节小端) [‖ "sAlT" 若 AESV2])` 取前 `min(keyLen+5,16)` 字节。
- V4 的 CFM 由 `/CF → /StmF 命名的子字典 → /CFM` 决定：`/V2`=RC4、`/AESV2`=AES-128-CBC（流前 16 字节为 IV，PKCS7 填充）。
- **不解密**：xref 流（在 `open()` 的 xref 循环内解析，早于安全处理器建立，且规范规定其永不加密）、`/Encrypt` 字典本身、字符串（YAGNI，见规格 §6.2）。
- **空密码优先**：先以 `""` 试一次（owner-only 加密静默通过，绝不惊动 provider）；失败才进入 provider 循环；provider 返回 `null` = 用户取消。
- **V5/R5-R6 在本任务内 `throw`（"added in Task 9"）**，Task 9 替换为真实现——这是刻意的增量边界，不是占位符。

- [ ] **Step 8.1: 写失败测试**

```dart
// test/pdf_security_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
  });

  group('standard security handler R2-R4', () {
    test('opens an RC4-128 encrypted PDF with the user password', () async {
      final images = await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
    });

    test('opens an AES-128 (V4) encrypted PDF with the user password',
        () async {
      final images = await extractPdfImages(
        _fixture('enc_aes128.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
    });

    test('owner-only PDF opens with the empty password, no provider needed',
        () async {
      final images = await extractPdfImages(_fixture('owner_only.pdf')).toList();
      expect(images.length, 2);
    });

    test('encrypted PDF without a provider throws PdfEncryptedException',
        () async {
      expect(
        () => extractPdfImages(_fixture('enc_rc4_128.pdf')).toList(),
        throwsA(isA<PdfEncryptedException>()),
      );
    });

    test('cancelling the prompt throws PdfCancelledException', () async {
      expect(
        () => extractPdfImages(
          _fixture('enc_rc4_128.pdf'),
          passwordProvider: (_) async => null,
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
    });
  });
}
```

- [ ] **Step 8.2: 运行确认失败**

Run: `flutter test test/pdf_security_test.dart`
Expected: FAIL（编译错误：`security.dart` 不存在；`PdfEncryptedException`/`PdfCancelledException`/`rc4` 未定义）

- [ ] **Step 8.3: objects.dart 追加异常类型**

在 `lib/utils/pdf/objects.dart` 末尾追加：

```dart
/// Thrown when the user cancels the password prompt (provider returns null).
/// Not a subtype of [PdfExtractException]: cancellation is a normal control
/// flow, not an extraction failure, and the UI must not toast it as an error.
class PdfCancelledException implements Exception {
  const PdfCancelledException();
  @override
  String toString() => 'Import cancelled';
}

/// Thrown when a document is encrypted and no [PdfPasswordProvider] is
/// available to ask for a password (headless / test path).
class PdfEncryptedException extends PdfExtractException {
  const PdfEncryptedException() : super('The PDF is encrypted');
}
```

- [ ] **Step 8.4: 实现 security.dart**

```dart
// lib/utils/pdf/security.dart
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

/// Pads/truncates a password to exactly 32 bytes (Algorithm 2, step a).
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

  /// Decrypts one stream's raw bytes. [objNum]/[objGen] drive the per-object
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
/// supplied. Must be called AFTER the xref/trailer are parsed but BEFORE any
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
  final v = (encrypt['V'] as PdfNumber?)?.intValue ?? 0;
  final r = (encrypt['R'] as PdfNumber?)?.intValue ?? 0;

  String? password = '';
  while (true) {
    final handler = _buildHandler(encrypt, v, r, id0, password);
    if (handler != null) {
      doc.security = handler;
      return;
    }
    if (passwordProvider == null) {
      throw const PdfEncryptedException();
    }
    password = await passwordProvider(fileName);
    if (password == null) {
      throw const PdfCancelledException();
    }
  }
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
  final encryptMetadata = (encrypt['EncryptMetadata'] as PdfBool?)?.value ?? true;

  if (v == 5) {
    // AES-256 (R5/R6) is implemented in Task 9.
    throw const PdfExtractException('AES-256 encrypted PDF support added in Task 9');
  }

  final o = _bytesOf(encrypt['O']);
  final u = _bytesOf(encrypt['U']);
  final p = (encrypt['P'] as PdfNumber?)?.intValue ?? 0;
  final keyBits =
      r >= 3 ? ((encrypt['Length'] as PdfNumber?)?.intValue ?? 128) : 40;
  final keyLen = keyBits ~/ 8;

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
  final expected = rc4(key, kPdfPasswordPadding);
  final n = u.length < 32 ? u.length : 32;
  return _eqBytes(expected.sublist(0, n), u.sublist(0, n));
}

/// Algorithm 5 (R3/R4): MD5(padding32 ‖ ID[0]) then 20 RC4 rounds; compare
/// the first 16 bytes with U[0:16].
bool _checkU3(Uint8List key, Uint8List id0, Uint8List u) {
  if (u.length < 16) return false;
  var data = Uint8List.fromList(
    md5.convert((BytesBuilder()
          ..add(kPdfPasswordPadding)
          ..add(id0))
        .toBytes())
        .bytes,
  );
  data = rc4(key, data);
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
```

- [ ] **Step 8.5: document.dart 接线解密**

在 `lib/utils/pdf/document.dart`：

1. 顶部 import 追加：`import 'security.dart';`
2. 把占位字段
   ```dart
   /// Set up by open() in Task 8 when the document is encrypted.
   Object? security;
   ```
   改为
   ```dart
   /// Set up by open() when the document is encrypted; null for plain PDFs.
   PdfSecurityHandler? security;
   ```
3. `open()` 内在 `trailer = firstTrailer;` 之后追加一行（xref 循环已完成，`/Encrypt` 可读）：
   ```dart
   trailer = firstTrailer;
   await setupSecurity(this,
       passwordProvider: passwordProvider, fileName: fileName);
   ```
4. `streamData()` 在按 `/Length` 切片之后、`return` 之前插入解密：
   ```dart
   Uint8List streamData(PdfStream stream) {
     final len = resolve(stream.dict['Length']);
     var raw = stream.raw;
     if (len is PdfNumber && len.intValue >= 0 && len.intValue <= raw.length) {
       raw = Uint8List.sublistView(raw, 0, len.intValue);
     }
     final sec = security;
     if (sec != null) {
       raw = sec.decryptStream(raw, stream.objNum, stream.objGen);
     }
     return raw;
   }
   ```

> 说明：xref 流在 `open()` 的 xref 循环里经 `PdfParser` 直接解析（早于 `setupSecurity`，且 `security` 此时为 null），因此天然不会被解密——符合"xref 流永不加密"的规范约束。ObjStm 与图片流都在 `security` 建立后经 `streamData()` 消费，故按需解密。

- [ ] **Step 8.6: 运行确认通过**

Run: `flutter test test/pdf_security_test.dart`
Expected: PASS（6 个测试）。若 `enc_aes128.pdf` 用例失败而 RC4 用例通过，多半是 V4 的 `/StmF`/`/CFM` 读取或 AES IV 切片问题——用 `test/fixtures/pdf/generate_fixtures.py` 的产物配合 `PdfDocument.open()` 打印 `/Encrypt` 字典核对。

- [ ] **Step 8.7: 全量回归 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿（含 Task 1-7）
```bash
git add lib/utils/pdf/security.dart lib/utils/pdf/objects.dart lib/utils/pdf/document.dart test/pdf_security_test.dart
git commit -m "feat: PDF standard security handler R2-R4 (RC4/AES-128) with password loop"
```

---

### Task 9: 标准安全处理器 R5/R6（AES-256）

**Files:**
- Modify: `lib/utils/pdf/security.dart`（替换 Task 8 的 V5 `throw`，新增 `buildAes256Handler`、`_hashR6`）
- Test: `test/pdf_security_test.dart`（追加 group）

**密码学要点：**
- R5/R6 的 `/U` 为 48 字节：`U[0:32]` 校验哈希、`U[32:40]` 校验盐、`U[40:48]` 密钥盐；`/UE` 为 32 字节（被加密的文件密钥）。
- 校验用户密码：`H(pw ‖ U[32:40]) == U[0:32]`。
- 取文件密钥：`inter = H(pw ‖ U[40:48])`；`fileKey = AES-256-CBC-Decrypt(key=inter, IV=0×16, data=UE[0:32])`（无填充）。
- `H`：R5 = 单次 SHA-256；R6 = Algorithm 2.B 密钥拉伸哈希。
- 密码用 UTF-8 编码，超过 127 字节截断。
- 每对象：R5/R6 直接用 32 字节文件密钥做 AES-256-CBC（流前 16 字节为 IV），无每对象密钥派生（Task 8 的 `PdfCipher.aes256` 分支已实现）。

> ⚠ **Algorithm 2.B 仲裁注记**：R6 哈希循环的规范表述在个别细节上存在流传差异。本实现与 qpdf/poppler 一致：每轮 `K1 = (input ‖ K ‖ E) × 64`（首轮 `E` 为空），`E = AES-128-CBC-Encrypt(key=K1[0:16], iv=K1[16:32], K1, 无填充)`，`K = {SHA256,SHA384,SHA512}[E[0] % 3](E)[0:32]`，退出条件 `round ≥ 64 且 (E[32] % 3) ≤ round - 32`，返回最后的 `K`。因为 `×64` 恒为 16 的倍数，`K1` 天然块对齐、无需填充。**`enc_aes256_r6.pdf` fixture 是唯一权威仲裁**：若下方 R6 测试失败，按序排查 (a) 退出字节 `E[32]` 是否被误写成 `E[0]`；(b) 首轮 `E` 种子（空 vs 32 个 0）；(c) `K` 更新的摘要选择是否用了 `E[0] % 3`。

- [ ] **Step 9.1: 追加失败测试**

在 `test/pdf_security_test.dart` 的 `main()` 内追加：

```dart
  group('standard security handler R5/R6 (AES-256)', () {
    test('opens an AES-256 (R6) encrypted PDF with the user password',
        () async {
      final images = await extractPdfImages(
        _fixture('enc_aes256_r6.pdf'),
        passwordProvider: (_) async => 'user123',
      ).toList();
      expect(images.length, 2);
      expect(images.every((i) => i.extension == 'jpg'), isTrue);
    });

    test('wrong password for an R6 PDF throws when cancelled', () async {
      var calls = 0;
      expect(
        () => extractPdfImages(
          _fixture('enc_aes256_r6.pdf'),
          passwordProvider: (_) async {
            calls++;
            return calls == 1 ? 'nope' : null;
          },
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
    });
  });
```

- [ ] **Step 9.2: 运行确认失败**

Run: `flutter test test/pdf_security_test.dart`
Expected: 新增 2 个用例 FAIL（V5 分支仍 `throw 'AES-256 ... Task 9'`）；原 6 个仍 PASS

- [ ] **Step 9.3: 实现 R5/R6**

在 `security.dart` 中，把 `_buildHandler` 里的 V5 分支：

```dart
  if (v == 5) {
    // AES-256 (R5/R6) is implemented in Task 9.
    throw const PdfExtractException('AES-256 encrypted PDF support added in Task 9');
  }
```

替换为：

```dart
  if (v == 5) {
    return _buildAes256Handler(encrypt, r, password, encryptMetadata);
  }
```

并在文件末尾追加：

```dart
/// R5/R6 (V5, AES-256). Validates the user password against /U and unwraps
/// the file key from /UE. Returns null on a wrong password.
PdfSecurityHandler? _buildAes256Handler(
  PdfDictionary encrypt,
  int r,
  String password,
  bool encryptMetadata,
) {
  final u = _bytesOf(encrypt['U']);
  final ue = _bytesOf(encrypt['UE']);
  if (u.length < 48 || ue.length < 32) return null;

  var pw = Uint8List.fromList(utf8.encode(password));
  if (pw.length > 127) pw = Uint8List.sublistView(pw, 0, 127);

  Uint8List hash(List<int> input) => r == 5
      ? Uint8List.fromList(sha256.convert(input).bytes)
      : _hashR6(input);

  // Validate: H(password ‖ U[32:40]) == U[0:32].
  final check = hash([...pw, ...u.sublist(32, 40)]);
  if (!_eqBytes(check, u.sublist(0, 32))) return null;

  // File key: AES-256-CBC decrypt UE under H(password ‖ U[40:48]), IV = 0.
  final inter = hash([...pw, ...u.sublist(40, 48)]);
  final fileKey =
      aesCbcDecryptNoPad(inter, Uint8List(16), ue.sublist(0, 32));

  return PdfSecurityHandler(
    fileKey: fileKey,
    cipher: PdfCipher.aes256,
    encryptMetadata: encryptMetadata,
  );
}

/// ISO 32000-2 Algorithm 2.B — the R6 key-stretching hash. See the arbitration
/// note in the implementation plan (Task 9) if the R6 fixture test fails.
Uint8List _hashR6(List<int> input) {
  final data = Uint8List.fromList(input);
  var k = Uint8List.fromList(sha256.convert(data).bytes);
  var e = Uint8List(0);
  var round = 0;
  while (true) {
    final k1 = BytesBuilder();
    for (var i = 0; i < 64; i++) {
      k1
        ..add(data)
        ..add(k)
        ..add(e);
    }
    final block = k1.toBytes();
    e = aesCbcEncryptNoPad(
      Uint8List.sublistView(block, 0, 16),
      Uint8List.sublistView(block, 16, 32),
      block,
    );
    final digest = switch (e[0] % 3) {
      0 => sha256.convert(e).bytes,
      1 => sha384.convert(e).bytes,
      _ => sha512.convert(e).bytes,
    };
    k = Uint8List.fromList(digest.sublist(0, 32));
    round++;
    if (round >= 64 && (e[32] % 3) <= round - 32) break;
  }
  return k;
}
```

- [ ] **Step 9.4: 运行确认通过**

Run: `flutter test test/pdf_security_test.dart`
Expected: PASS（8 个测试）

- [ ] **Step 9.5: 全量回归 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿
```bash
git add lib/utils/pdf/security.dart test/pdf_security_test.dart
git commit -m "feat: PDF standard security handler R5/R6 (AES-256)"
```

---

### Task 10: 密码提供者契约测试

**Files:**
- Test: `test/pdf_password_test.dart`

固化 `passwordProvider` 的三条契约（规格 §6.3）：错后重试成功、错后取消抛 `PdfCancelledException`、空密码（owner-only）绝不惊动 provider。纯测试任务，无生产代码改动——若任一用例失败，说明 Task 8/9 的循环逻辑有缺陷，回到对应任务修正。

- [ ] **Step 10.1: 写测试**

```dart
// test/pdf_password_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/pdf/$name').readAsBytesSync();

void main() {
  group('PdfPasswordProvider contract', () {
    test('retries the provider after a wrong password, then succeeds',
        () async {
      var calls = 0;
      final images = await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        passwordProvider: (_) async {
          calls++;
          return calls == 1 ? 'wrong' : 'user123';
        },
      ).toList();
      expect(images.length, 2);
      expect(calls, 2);
    });

    test('cancel after a wrong password throws PdfCancelledException',
        () async {
      var calls = 0;
      expect(
        () => extractPdfImages(
          _fixture('enc_rc4_128.pdf'),
          passwordProvider: (_) async {
            calls++;
            return calls == 1 ? 'wrong' : null;
          },
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
    });

    test('owner-only PDF never invokes the provider', () async {
      final images = await extractPdfImages(
        _fixture('owner_only.pdf'),
        passwordProvider: (_) async =>
            throw StateError('provider must not be called for empty password'),
      ).toList();
      expect(images.length, 2);
    });

    test('provider receives the file name for the dialog title', () async {
      String? seen;
      await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        fileName: 'secret.pdf',
        passwordProvider: (name) async {
          seen = name;
          return 'user123';
        },
      ).toList();
      expect(seen, 'secret.pdf');
    });
  });
}
```

- [ ] **Step 10.2: 运行**

Run: `flutter test test/pdf_password_test.dart`
Expected: PASS（4 个测试）。若有 FAIL，修 Task 8/9 的 `setupSecurity` 循环，不改本测试。

- [ ] **Step 10.3: 提交**

```bash
git add test/pdf_password_test.dart
git commit -m "test: PDF password provider retry/cancel/empty-password contract"
```

---

### Task 11: LocalManager 测试接缝 + CBZ 共用尾段抽取

**Files:**
- Modify: `lib/foundation/local.dart`（`LocalManager.forTesting` / `debugSetInstance` / 抽出 `_createComicsTable`）
- Modify: `lib/utils/cbz.dart`（抽出 `comicFromCacheDir`，`CBZ.import` 改为调用它）
- Test: `test/cbz_import_test.dart`

`comicFromCacheDir` 是 CBZ 与 PDF 导入的共用尾段（规格 §7.1）：接收一个已含图片文件的缓存目录，产出磁盘上的漫画目录与 `LocalComic`（**不**注册进 DB、**不**删缓存，由调用方负责）。`LocalManager.forTesting` 是六单例中唯一缺失的测试接缝（AGENTS.md 要求 foundation/ 改动带测试）。

- [ ] **Step 11.1: 写失败测试**

```dart
// test/cbz_import_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('CBZ.comicFromCacheDir', () {
    late Directory tmp;
    late Directory local;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cbz_tail');
      local = Directory(FilePath.join(tmp.path, 'local'))..createSync();
      LocalManager.debugSetInstance(LocalManager.forTesting(local.path));
    });

    tearDown(() {
      LocalManager.debugSetInstance(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // comicFromCacheDir copies bytes verbatim; extension is all that matters.
    Uint8List fake() => Uint8List.fromList([1, 2, 3, 4]);

    // Each call gets its own subdirectory so multiple caches can coexist.
    var cacheSeq = 0;
    Directory makeCache(List<String> names) {
      final cache =
          Directory(FilePath.join(tmp.path, 'cache${cacheSeq++}'))..createSync();
      for (final n in names) {
        File(FilePath.join(cache.path, n)).writeAsBytesSync(fake());
      }
      return cache;
    }

    test('lays out cover + numbered pages and builds the LocalComic', () async {
      final cache = makeCache(['cover.png', '1.png', '2.png', '3.png']);

      final comic = await CBZ.comicFromCacheDir(cache, title: 'My Comic');

      expect(comic.title, 'My Comic');
      expect(comic.cover, 'cover.png');
      expect(comic.hasChapters, isFalse);
      final dir = Directory(FilePath.join(local.path, comic.directory));
      expect(dir.existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, 'cover.png')).existsSync(), isTrue);
      // cover.* is consumed as the cover; the rest are renumbered 1..n.
      expect(File(FilePath.join(dir.path, '1.png')).existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, '2.png')).existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, '3.png')).existsSync(), isTrue);
    });

    test('uses the first image as cover when no cover.* exists', () async {
      final cache = makeCache(['1.jpg', '2.jpg']);

      final comic = await CBZ.comicFromCacheDir(cache, title: 'No Cover');

      expect(comic.cover, 'cover.jpg');
      final dir = Directory(FilePath.join(local.path, comic.directory));
      expect(File(FilePath.join(dir.path, 'cover.jpg')).existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, '1.jpg')).existsSync(), isTrue);
    });

    test('rejects a title that already exists in the library', () async {
      // comicFromCacheDir does not register the comic (registerComics does),
      // so simulate a prior import by adding one with the same title.
      await LocalManager().add(LocalComic(
        id: LocalManager().findValidId(ComicType.local),
        title: 'Dup',
        subtitle: '',
        tags: const [],
        directory: 'Dup',
        chapters: null,
        cover: 'cover.png',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.now(),
      ));
      final cache = makeCache(['1.png']);

      expect(
        () => CBZ.comicFromCacheDir(cache, title: 'Dup'),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the cache holds no supported images', () async {
      final cache = makeCache(['notes.txt']);

      expect(
        () => CBZ.comicFromCacheDir(cache, title: 'Empty'),
        throwsA(isA<Exception>()),
      );
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
```

> `findByName` 匹配 `title` 或 `directory`；`comicFromCacheDir` 只读取 DB 做查重、不写入，因此重复标题需由调用链后续的 `registerComics` 落库后才会被下一次导入检出——测试用 `LocalManager().add` 直接预置一条同名记录来覆盖该分支。

- [ ] **Step 11.2: 运行确认失败**

Run: `flutter test test/cbz_import_test.dart`
Expected: FAIL（`LocalManager.forTesting` / `debugSetInstance` / `CBZ.comicFromCacheDir` 未定义）

- [ ] **Step 11.3: local.dart 加测试接缝**

1. import 追加：`import 'package:flutter/foundation.dart' show visibleForTesting;`
2. `init()` 中内联的 `CREATE TABLE ... comics ...` 语句抽成方法，`init()` 改为调用它：
   ```dart
   /// Schema shared by [init] and [LocalManager.forTesting].
   void _createComicsTable() {
     _db.execute('''
       CREATE TABLE IF NOT EXISTS comics (
         id TEXT NOT NULL,
         title TEXT NOT NULL,
         subtitle TEXT NOT NULL,
         tags TEXT NOT NULL,
         directory TEXT NOT NULL,
         chapters TEXT NOT NULL,
         cover TEXT NOT NULL,
         comic_type INTEGER NOT NULL,
         downloadedChapters TEXT NOT NULL,
         created_at INTEGER,
         PRIMARY KEY (id, comic_type)
       );
     ''');
   }
   ```
   （`init()` 里原先的 `_db.execute('''CREATE TABLE ...''')` 整段替换为 `_createComicsTable();`）
3. 在 `LocalManager._();` 附近追加测试构造与 setter：
   ```dart
   /// Creates a manager backed by an in-memory database rooted at [testPath],
   /// skipping file I/O and download-task restore. For unit tests only.
   @visibleForTesting
   LocalManager.forTesting(String testPath) {
     _db = sqlite3.openInMemory();
     _createComicsTable();
     path = testPath;
   }

   /// Replaces (or clears) the factory singleton. For unit tests only.
   @visibleForTesting
   static void debugSetInstance(LocalManager? instance) {
     _instance = instance;
   }
   ```

- [ ] **Step 11.4: cbz.dart 抽出 comicFromCacheDir**

把 `CBZ.import` 中从 `var old = LocalManager().findByName(...)` 到构造并返回 `LocalComic` 的整段（当前 107-183 行）替换为对新方法的调用，并新增该静态方法。改后的 `import`：

```dart
  static Future<LocalComic> import(File file) async {
    var root = Directory(FilePath.join(App.cachePath, 'cbz_import'));
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync();
    await extractArchive(file, root);
    var cache = root;
    var f = root.listSync();
    if (f.length == 1 && f.first is Directory) {
      cache = f.first as Directory;
    }
    var metaDataFile = File(FilePath.join(cache.path, 'metadata.json'));
    ComicMetaData? metaData;
    if (metaDataFile.existsSync()) {
      try {
        metaData =
            ComicMetaData.fromJson(jsonDecode(metaDataFile.readAsStringSync()));
      } catch (_) {}
    }
    metaData ??= ComicMetaData(
      title: file.name.substring(0, file.name.lastIndexOf('.')),
      author: "",
      tags: [],
    );
    try {
      return await comicFromCacheDir(
        cache,
        title: metaData.title,
        author: metaData.author,
        tags: metaData.tags,
        chapters: metaData.chapters,
      );
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }

  /// Shared import tail for archive and PDF imports (spec §7.1): given a
  /// directory of already-extracted image files, build the on-disk comic
  /// folder under [LocalManager.path] and return its [LocalComic].
  ///
  /// Does NOT register the comic in the database and does NOT delete [cache];
  /// the caller owns both. [title] must carry no file extension.
  static Future<LocalComic> comicFromCacheDir(
    Directory cache, {
    required String title,
    String author = '',
    List<String> tags = const [],
    List<ComicChapter>? chapters,
  }) async {
    var old = LocalManager().findByName(title);
    if (old != null) {
      throw Exception('Comic with name $title already exists');
    }
    var files = cache.listSync().whereType<File>().toList();
    files.removeWhere((e) => !isSupportedImageName(e.name));
    if (files.isEmpty) {
      throw Exception('No images found in the archive');
    }
    files.sort((a, b) {
      var aIndex = int.tryParse(a.basenameWithoutExt);
      var bIndex = int.tryParse(b.basenameWithoutExt);
      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      return a.path.compareTo(b.path);
    });
    var coverFile = files.firstWhereOrNull(
      (e) => e.path.endsWith('cover.${e.path.split('.').last}'),
    );
    if (coverFile != null) {
      files.remove(coverFile);
    } else {
      coverFile = files.first;
    }
    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(LocalManager().path, sanitizeFileName(title)),
    );
    dest.createSync();
    coverFile.copyMem(FilePath.join(dest.path, 'cover.${coverFile.extension}'));
    if (chapters == null) {
      for (var i = 0; i < files.length; i++) {
        var src = files[i];
        var dst = File(
            FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'));
        await src.copyMem(dst.path);
      }
    } else {
      var grouped = <String, List<File>>{};
      for (var chapter in chapters) {
        grouped[chapter.title] = files.sublist(chapter.start - 1, chapter.end);
      }
      int i = 0;
      cpMap = <String, String>{};
      for (var chapter in grouped.entries) {
        cpMap[i.toString()] = chapter.key;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        for (var j = 0; j < chapter.value.length; j++) {
          var src = chapter.value[j];
          var dst = File(FilePath.join(
              chapterDir.path, '${j + 1}.${src.path.split('.').last}'));
          await src.copyMem(dst.path);
        }
      }
    }
    return LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: title,
      subtitle: author,
      tags: tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
    );
  }
```

> 行为保持：错误信息（`Comic with name X already exists` / `No images found in the archive`）、排序、cover 选择、目录布局、`LocalComic` 字段全部与重构前一致；唯一差异是缓存目录改由调用方在 `finally` 中删除（原来在成功路径末尾删），对 cbz 成功/失败路径的可见行为无影响。

- [ ] **Step 11.5: 运行确认通过**

Run: `flutter test test/cbz_import_test.dart`
Expected: PASS（4 个测试）

- [ ] **Step 11.6: 全量回归 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿（`local_comic_test.dart` 等既有 foundation 测试不受影响）
```bash
git add lib/foundation/local.dart lib/utils/cbz.dart test/cbz_import_test.dart
git commit -m "refactor: extract shared comicFromCacheDir tail and add LocalManager test seam"
```

---

### Task 12: PdfComic.import + 端到端集成测试

**Files:**
- Create: `lib/utils/pdf_import.dart`
- Test: `test/pdf_import_test.dart`

`PdfComic.import` 与 `CBZ.import` 同构：解析（含解密）→ 图片写入 `App.cachePath/pdf_import/`（命名 `1.jpg`/`2.png`… 页序）→ 调 `CBZ.comicFromCacheDir`（标题 = 文件名去扩展名，与 cbz 一致）→ 返回 `LocalComic`。

- [ ] **Step 12.1: 写失败测试**

```dart
// test/pdf_import_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf_import.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('PdfComic.import', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pdf_import');
      App.cachePath = tmp.path;
      App.dataPath = tmp.path;
      final localPath = FilePath.join(tmp.path, 'local');
      Directory(localPath).createSync(recursive: true);
      LocalManager.debugSetInstance(LocalManager.forTesting(localPath));
    });

    tearDown(() {
      LocalManager.debugSetInstance(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('imports the plain JPEG fixture end to end', () async {
      final comic =
          await PdfComic.import(File('test/fixtures/pdf/plain_jpeg.pdf'));

      expect(comic.title, 'plain_jpeg');
      expect(comic.cover, 'cover.jpg');
      expect(comic.hasChapters, isFalse);
      final dir = Directory(FilePath.join(LocalManager().path, comic.directory));
      expect(dir.existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, 'cover.jpg')).existsSync(), isTrue);
      // 2 page images: the first becomes cover.jpg, the second becomes 1.jpg.
      expect(File(FilePath.join(dir.path, '1.jpg')).existsSync(), isTrue);
      // The transient cache dir is cleaned up.
      expect(Directory(FilePath.join(tmp.path, 'pdf_import')).existsSync(),
          isFalse);
    });

    test('imports an encrypted (R6) PDF via a password provider', () async {
      final comic = await PdfComic.import(
        File('test/fixtures/pdf/enc_aes256_r6.pdf'),
        passwordProvider: (_) async => 'user123',
      );

      expect(comic.title, 'enc_aes256_r6');
      expect(comic.cover, 'cover.jpg');
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
```

- [ ] **Step 12.2: 运行确认失败**

Run: `flutter test test/pdf_import_test.dart`
Expected: FAIL（`pdf_import.dart` / `PdfComic` 不存在）

- [ ] **Step 12.3: 实现 pdf_import.dart**

```dart
// lib/utils/pdf_import.dart
import 'dart:io';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';

/// Imports an image-based comic PDF, mirroring [CBZ.import]: extract every
/// page image into a cache directory, then run the shared registration tail.
///
/// JPEG pages are copied through untouched; Flate pages are re-encoded as PNG
/// (see utils/pdf/images.dart). Encrypted PDFs prompt via [passwordProvider].
abstract class PdfComic {
  static Future<LocalComic> import(
    File file, {
    PdfPasswordProvider? passwordProvider,
  }) async {
    final data = await file.readAsBytes();
    final cache = Directory(FilePath.join(App.cachePath, 'pdf_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync(recursive: true);
    final name = file.name;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    try {
      var index = 1;
      await for (final image in extractPdfImages(
        data,
        passwordProvider: passwordProvider,
        fileName: name,
      )) {
        final out =
            File(FilePath.join(cache.path, '$index.${image.extension}'));
        await out.writeAsBytes(image.bytes);
        index++;
      }
      return await CBZ.comicFromCacheDir(cache, title: title);
    } finally {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    }
  }
}
```

- [ ] **Step 12.4: 运行确认通过**

Run: `flutter test test/pdf_import_test.dart`
Expected: PASS（2 个测试）

- [ ] **Step 12.5: 全量回归 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿
```bash
git add lib/utils/pdf_import.dart test/pdf_import_test.dart
git commit -m "feat: PdfComic.import end-to-end image-based PDF import"
```

---

### Task 13: UI 接线（导入对话框 + 密码框 + i18n）

**Files:**
- Modify: `lib/components/message.dart`（`showInputDialog` 增加 `obscureText`）
- Modify: `lib/utils/import_comic.dart`（`passwordProvider` 字段、`pdf()`/`multiplePdf()`、`wrapPasswordProvider`、`pdfErrorMessage`）
- Modify: `lib/pages/home_page.dart`（导入对话框插入两个 PDF 选项、索引调整、密码对话框 `_askPdfPassword`、`dart:async` import）
- Modify: `assets/translation.json`（zh_CN + zh_TW 各 9 键）
- Test: `test/import_comic_pdf_test.dart`

`import_comic.dart` 属 utils/，**不能** import components/ 或 pages/（架构测试会拦截）。因此密码对话框本体在 home_page.dart 构造，通过 `ImportComic.passwordProvider` 字段注入；utils 侧只保留可单测的纯逻辑（错误信息映射、重试提示包装）。

- [ ] **Step 13.1: 写失败测试（纯逻辑部分）**

```dart
// test/import_comic_pdf_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';

void main() {
  group('pdfErrorMessage', () {
    test('maps known PDF errors to non-empty user-facing strings', () {
      expect(pdfErrorMessage(PdfNoImagesException()), isNotEmpty);
      expect(
          pdfErrorMessage(PdfUnsupportedEncodingException(2, 'JPXDecode')),
          isNotEmpty);
      expect(pdfErrorMessage(const PdfEncryptedException()), isNotEmpty);
    });

    test('passes through unrelated exceptions via toString', () {
      expect(pdfErrorMessage(Exception('boom')), 'Exception: boom');
    });
  });

  group('ImportComic.wrapPasswordProvider', () {
    test('toasts "Incorrect password" only after the first attempt', () async {
      final messages = <String>[];
      final answers = <String?>['wrong', 'right'];
      var i = 0;
      final importer = ImportComic(
        showMessage: messages.add,
        showLoading: ({message, allowCancel = true, onCancel}) => null,
        passwordProvider: (_) async => answers[i++],
      );

      final wrapped = importer.wrapPasswordProvider(importer.passwordProvider!);
      expect(await wrapped('f.pdf'), 'wrong');
      expect(messages, isEmpty); // first attempt: no toast yet
      expect(await wrapped('f.pdf'), 'right');
      expect(messages.length, 1); // second attempt: toasted the failure
    });
  });
}
```

- [ ] **Step 13.2: 运行确认失败**

Run: `flutter test test/import_comic_pdf_test.dart`
Expected: FAIL（`pdfErrorMessage` / `ImportComic.wrapPasswordProvider` / `passwordProvider` 字段未定义）

- [ ] **Step 13.3: message.dart 增加 obscureText**

`showInputDialog` 的签名参数列表末尾加 `bool obscureText = false,`，并把内部 `TextField(` 改为：

```dart
                TextField(
                  controller: controller,
                  obscureText: obscureText,
                  decoration: InputDecoration(
                    hintText: hintText,
                    border: const OutlineInputBorder(),
                    errorText: error,
                  ),
                ).paddingHorizontal(12),
```

- [ ] **Step 13.4: import_comic.dart 增加 PDF 入口**

1. import 追加：
   ```dart
   import 'package:venera/utils/pdf/images.dart';
   import 'package:venera/utils/pdf/objects.dart';
   import 'package:venera/utils/pdf_import.dart';
   ```
2. `ImportComic` 类增加字段与构造参数（保持 `const`）：
   ```dart
   /// Injected by the UI layer to prompt for a password on encrypted PDFs.
   /// Null in headless/test paths (only empty-password PDFs can be opened).
   final PdfPasswordProvider? passwordProvider;
   ```
   构造函数参数列表加 `this.passwordProvider,`。
3. 在类内新增（`multipleCbz()` 之后即可）：
   ```dart
   /// Wraps [inner] so the second and later prompts surface an
   /// "Incorrect password" toast (the first prompt follows a silent
   /// empty-password attempt inside the parser, so it must not toast).
   PdfPasswordProvider wrapPasswordProvider(PdfPasswordProvider inner) {
     var attempts = 0;
     return (fileName) async {
       if (attempts > 0) showMessage("Incorrect password".tl);
       attempts++;
       return inner(fileName);
     };
   }

   PdfPasswordProvider? get _wrappedProvider =>
       passwordProvider == null ? null : wrapPasswordProvider(passwordProvider!);

   Future<bool> pdf() async {
     var file = await selectFile(ext: ['pdf'], onError: showMessage);
     if (file == null) return false;
     var controller = showLoading(allowCancel: true);
     Map<String?, List<LocalComic>> imported = {};
     try {
       var comic = await PdfComic.import(
         File(file.path),
         passwordProvider: _wrappedProvider,
       );
       imported[selectedFolder] = [comic];
     } on PdfCancelledException {
       controller.close();
       return false;
     } catch (e, s) {
       Log.error("Import Comic", e.toString(), s);
       showMessage(pdfErrorMessage(e));
       controller.close();
       return false;
     }
     controller.close();
     return registerComics(imported, false);
   }

   Future<bool> multiplePdf() async {
     var picker = DirectoryPicker();
     var dir = await picker.pickDirectory(directAccess: true);
     if (dir == null) return false;
     var files = (await dir.list().toList()).whereType<File>().toList();
     files.removeWhere((e) => e.extension.toLowerCase() != 'pdf');
     var controller = showLoading(allowCancel: false);
     var comics = <LocalComic>[];
     for (var file in files) {
       try {
         var comic = await PdfComic.import(
           file,
           passwordProvider: _wrappedProvider,
         );
         comics.add(comic);
       } on PdfCancelledException {
         // User skipped this file; continue with the rest (spec §6.4).
       } catch (e, s) {
         Log.error("Import Comic", e.toString(), s);
       }
     }
     if (comics.isEmpty) {
       showMessage("No valid comics found".tl);
     }
     controller.close();
     Map<String?, List<LocalComic>> imported = {selectedFolder: comics};
     return registerComics(imported, false);
   }
   ```
4. 文件顶层（`ImportComic` 类之外）新增纯函数：
   ```dart
   /// Maps a PDF extraction failure to a localized, user-facing message.
   String pdfErrorMessage(Object e) {
     if (e is PdfUnsupportedEncodingException) {
       return "PDF page @p uses an unsupported image encoding (@e)"
           .tlParams({'p': e.page, 'e': e.filter});
     }
     if (e is PdfNoImagesException) return "No images found in the PDF".tl;
     if (e is PdfEncryptedException) return "The PDF is encrypted".tl;
     return e.toString();
   }
   ```

> `_wrappedProvider` 每次访问都新建一个 `attempts` 计数闭包——`pdf()`/`multiplePdf()` 各自在单次导入内多次读取它吗？不：`pdf()` 只读一次传给 `PdfComic.import`；`multiplePdf()` 在循环里每个文件读一次，因此**每个文件独立计数**（符合"逐文件重弹、互不串扰"）。

- [ ] **Step 13.5: home_page.dart 插入 PDF 选项**

1. 顶部 import 追加：
   ```dart
   import 'dart:async';
   ```
2. `_ImportComicsWidgetState.build` 内的 `info` 数组替换为（插入索引 4/5）：
   ```dart
     String info = [
       "Select a directory which contains the comic files.".tl,
       "Select a directory which contains the comic directories.".tl,
       "Select an archive file (cbz, zip, 7z, cb7)".tl,
       "Select a directory which contains multiple archive files.".tl,
       "Select a PDF file (image-based comics).".tl,
       "Select a directory which contains PDF files.".tl,
       "Select an EhViewer database and a download folder.".tl,
       "Scan the current local path and restore the local database.".tl,
     ][type];
   ```
3. `importMethods` 替换为：
   ```dart
     List<String> importMethods = [
       "Single Comic".tl,
       "Multiple Comics".tl,
       "An archive file".tl,
       "Multiple archive files".tl,
       "A PDF file".tl,
       "Multiple PDF files".tl,
       "EhViewer downloads".tl,
       "Restore local downloads".tl,
     ];
   ```
4. `RadioGroup<int>` 的 `onChanged` 里 `if (type == 5)` 改为 `if (type == 7)`（restore 现在索引 7，切到它时清空 selectedFolder）。
5. 收藏夹选择器条件 `if (type != 4 && type != 5)` 改为 `if (type != 6 && type != 7)`（ehViewer=6、restore=7 无收藏夹选择）。
6. 复制到本地路径的复选框条件改为：
   ```dart
     if (!App.isIOS &&
         !App.isMacOS &&
         type != 2 &&
         type != 3 &&
         type != 4 &&
         type != 5 &&
         type != 7)
   ```
   （cbz=2、multipleCbz=3、pdf=4、multiplePdf=5、restore=7 都强制复制到本地路径，不显示复选框；single/multiple directory=0/1 与 ehViewer=6 保留。）
7. `selectAndImport` 的 switch 替换为：
   ```dart
     var result = switch (type) {
       0 => await importer.directory(true),
       1 => await importer.directory(false),
       2 => await importer.cbz(),
       3 => await importer.multipleCbz(),
       4 => await importer.pdf(),
       5 => await importer.multiplePdf(),
       6 => await importer.ehViewer(),
       7 => await importer.localDownloads(),
       int() => true,
     };
   ```
8. `ImportComic(...)` 构造增加 `passwordProvider: _askPdfPassword,`。
9. 在 `_ImportComicsWidgetState` 内新增方法（Completer 桥接命令式 `showInputDialog` 与解析器的 `await provider(...)` 循环）：
   ```dart
   /// Bridges the parser's `await passwordProvider(fileName)` loop to a modal
   /// dialog. Resolves with the entered password, or null when dismissed
   /// (treated as cancel by the parser).
   Future<String?> _askPdfPassword(String fileName) {
     final completer = Completer<String?>();
     showInputDialog(
       context: App.rootContext,
       title: "Enter password for @f".tlParams({'f': fileName}),
       obscureText: true,
       onConfirm: (text) {
         completer.complete(text);
         return null; // close the dialog
       },
     ).then((_) {
       if (!completer.isCompleted) completer.complete(null);
     });
     return completer.future;
   }
   ```
   > `showInputDialog` 的 `onConfirm` 返回 `null` 会关闭对话框；对话框因关闭按钮/遮罩被 dismiss 时 `showDialog` 的 future 完成而 completer 未完成 → 补 `null`（取消）。密码对错由解析器判定：错则会再次调用 `_askPdfPassword`（配合 `wrapPasswordProvider` 弹 "Incorrect password" 提示）。

- [ ] **Step 13.6: translation.json 增加 9 键**

在 `assets/translation.json` 的 `zh_CN` 段与 `zh_TW` 段，各自紧跟 `"Request timed out": ...` 之后插入以下键值（保持 JSON 合法：注意逗号）。

zh_CN：
```json
    "A PDF file": "单个 PDF 文件",
    "Multiple PDF files": "多个 PDF 文件",
    "Select a PDF file (image-based comics).": "选择一个 PDF 文件（图片型漫画）。",
    "Select a directory which contains PDF files.": "选择一个包含 PDF 文件的目录。",
    "Enter password for @f": "输入 @f 的密码",
    "Incorrect password": "密码错误",
    "The PDF is encrypted": "该 PDF 已加密",
    "PDF page @p uses an unsupported image encoding (@e)": "PDF 第 @p 页使用了不支持的图片编码（@e）",
    "No images found in the PDF": "未在 PDF 中找到图片",
```

zh_TW：
```json
    "A PDF file": "單個 PDF 檔案",
    "Multiple PDF files": "多個 PDF 檔案",
    "Select a PDF file (image-based comics).": "選擇一個 PDF 檔案（圖片型漫畫）。",
    "Select a directory which contains PDF files.": "選擇一個包含 PDF 檔案的目錄。",
    "Enter password for @f": "輸入 @f 的密碼",
    "Incorrect password": "密碼錯誤",
    "The PDF is encrypted": "該 PDF 已加密",
    "PDF page @p uses an unsupported image encoding (@e)": "PDF 第 @p 頁使用了不支援的圖片編碼（@e）",
    "No images found in the PDF": "未在 PDF 中找到圖片",
```

- [ ] **Step 13.7: 运行确认通过**

Run: `flutter test test/import_comic_pdf_test.dart`
Expected: PASS（3 个测试）

- [ ] **Step 13.8: 全量回归 + JSON 合法性 + 提交**

Run: `flutter analyze` → No issues；`flutter test` → 全绿
校验 JSON：`python -c "import json; json.load(open('assets/translation.json', encoding='utf-8'))"` → 无输出即合法。
```bash
git add lib/components/message.dart lib/utils/import_comic.dart lib/pages/home_page.dart assets/translation.json test/import_comic_pdf_test.dart
git commit -m "feat: PDF import UI - dialog options, password prompt, i18n"
```

> **手动 QA（实施者在真机/桌面跑一次，无法自动化）：** 导入对话框出现 "A PDF file"/"Multiple PDF files" 两项且序号正确；选单个未加密 PDF 成功导入并在本地漫画页出现；选加密 PDF 弹密码框，输错弹 "Incorrect password" 并重弹，输对成功，取消则终止无报错；批量选目录逐个导入、单个取消只跳过该文件。UI 层无法在 `flutter test` 中覆盖，故列为交付前手动检查项。

---

### Task 14: 文档、上游 issue 登记与全量验证

**Files:**
- Modify: `doc/import_comic.md`（新增 PDF 章节）
- Modify: `design/upstream_issues/ANALYSIS.md`（#431 状态从"暂缓"更新为"已实现"）
- Modify: `README.md`（若"Import Comic"能力清单提及格式，补 PDF）

- [ ] **Step 14.1: doc/import_comic.md 增补 PDF 章节**

在文件末尾（"## Archive" 段之后）追加：

```markdown
## PDF

Venera supports importing **image-based comic PDFs** — PDFs whose pages are
scanned/illustrated images (one image per page). Each imported PDF becomes a
single chapterless comic, mirroring the archive import behaviour.

- Open `Local` -> `Import` -> `A PDF file` (single) or `Multiple PDF files`
  (a directory of PDFs).
- The comic title is the file name without its extension (PDF metadata is not
  used, matching archive import).
- JPEG pages (`/DCTDecode`) are passed through byte-for-byte (lossless);
  Flate pages (`/FlateDecode`) are converted to PNG.

**Encryption.** Password-protected PDFs are supported:

- Empty user password (owner-password-only files) open silently.
- Otherwise a password dialog appears (its title shows the file name). A wrong
  password shows "Incorrect password" and re-prompts; cancelling aborts that
  file. In batch import, cancelling skips only the current file.

**Supported image encodings.** DeviceRGB / DeviceGray / DeviceCMYK (including
Adobe-inverted CMYK), `/ICCBased` (mapped by component count) and `/Indexed`
palettes, at 8 or 16 bits per component (16 is downsampled to 8). Standard
security handler revisions R2-R6 (RC4-40/128, AES-128, AES-256) are supported.

**Not supported.** Vector/text-only pages (a PDF with no page images reports
"No images found in the PDF"), inline images (`BI`/`ID`/`EI`), and the
`JPXDecode` / `CCITTFaxDecode` / `JBIG2Decode` encodings — for those, convert
the PDF to a `.cbz` with an external tool first. The error message names the
page number and encoding.
```

- [ ] **Step 14.2: ANALYSIS.md 更新 #431**

在 `design/upstream_issues/ANALYSIS.md` 的"## 四、状态复核记录（持续更新）"表格末尾追加一行：

```markdown
| #431 支持导入 PDF | ✅ 已在 venera-D 实现 | 上游归档、无维护者回应；venera-D 自研纯 Dart PDF 子集解析器（`lib/utils/pdf/`）：图片型漫画 PDF 导入，DCTDecode JPEG 直通 + FlateDecode 转 PNG，标准安全处理器 R2-R6（RC4/AES-128/AES-256）含密码 UI；零新增依赖（复用 crypto/pointycastle）；设计见 `doc/specs/2026-09-13-pdf-comic-import-design.md`，实施计划见 `doc/plans/2026-09-13-pdf-comic-import.md`，测试见 `test/pdf_*_test.dart` |
```

并把"## 五、批量复核记录"表格中 `#312/#369/#431/#371 格式支持` 那一行的结论里 `#431` 单独标注为已实现（例如在该行"复核结论"列补一句：`其中 #431(pdf) 已于 2026-09 在 venera-D 实现，见第四节`）。

- [ ] **Step 14.3: README.md 检查**

Run: `grep -niE "cbz|archive|import|pdf" README.md`
若 README 存在列举可导入格式的清单（当前仅第 76 行链接到 `doc/import_comic.md`，无格式清单），在其中补 PDF；若无格式清单则**不改** README（避免无意义改动），仅在链接描述保持不变即可。

- [ ] **Step 14.4: 全量验证**

Run:
```bash
flutter analyze
flutter test
python -c "import json; json.load(open('assets/translation.json', encoding='utf-8'))"
```
Expected:
- `flutter analyze` → `No issues found!`
- `flutter test` → 全绿，测试数 = 184（基线）+ 本计划新增（Task1:4、Task2:11、Task3:6、Task4:2、Task5:3、Task6:13、Task7:6、Task8:6、Task9:2、Task10:4、Task11:4、Task12:2、Task13:3 = 66）= **250** 左右（以实际为准，关键是 0 失败）
- JSON 校验无输出（合法）

- [ ] **Step 14.5: 提交**

```bash
git add doc/import_comic.md design/upstream_issues/ANALYSIS.md README.md
git commit -m "docs: document image-based PDF import and close out upstream #431"
```

---

## 自检记录（writing-plans Self-Review）

**1. 规格覆盖（doc/specs/2026-09-13-pdf-comic-import-design.md 逐节）：**
- §4 模块布局 → Task 1(png_encoder)/2(objects)/3(document)/8-9(security)/6(images)/12(pdf_import)/11(cbz 尾段+LocalManager 接缝)/13(import_comic+home_page+message+translation)/7(fixtures+helpers) 全覆盖
- §5.1 结构解析（startxref/传统+流 xref/ObjStm/页树+资源继承/每页图片）→ Task 3/4/5
- §5.2 图片提取（DCT 直通/Flate→PNG/Predictor/ColorSpace 含 Indexed+ICCBased/8+16bpc/SMask+ImageMask 忽略/JPX 等拒绝/一页多图资源名序）→ Task 6
- §5.3 手写 PNG 编码器 → Task 1
- §5.4 明确不做（矢量/文字页报 No images、内联图片、章节、metadata.json）→ Task 6(NoImages)/12
- §6.1-6.2 安全处理器 R2-R6/密钥推导/每对象密钥/EncryptMetadata/字符串不解密/密码编码 → Task 8(R2-R4)/9(R5-R6)
- §6.3 解密层位置+PdfPasswordProvider(带 fileName)+空密码优先+provider 循环+取消 → Task 8(setupSecurity)/10(契约)
- §6.4 UI 流程（单文件/批量密码框、错误重弹、取消跳过）→ Task 13
- §7.1 共用尾段 comicFromCacheDir → Task 11
- §7.2 PdfComic.import → Task 12
- §7.3 ImportComic.pdf()/multiplePdf() → Task 13
- §7.4 home_page 索引 4/5 插入 + 全部条件同步 → Task 13
- §7.5 i18n 9 键 zh_CN+zh_TW → Task 13
- §8 错误处理表 → Task 6(不支持编码含页码)/8(取消/加密)/12(No images)/11(重名)/13(批量跳过)
- §9 测试策略（fixture/读写互证/密码学算例/单测/集成/回归/架构）→ Task 7(fixtures)/8(RC4 向量)/9(R6)/10(契约)/11(回归)/12(集成)；"读写互证"（用 utils/pdf.dart 写出器生成 Flate PDF 再提取）已并入 Task 6 的 FlateDecode 用例
- §11 决策记录 → 各任务的实现选择与之一致

**2. 占位符扫描：** 无 "TBD/待补/类似上文/适当处理" 等。Task 8 的 V5 `throw` 是刻意的增量边界并在 Task 9 明确替换，非占位符。所有代码步骤均给出完整可粘贴代码。

**3. 类型一致性（跨任务符号核对）：**
- `PdfPasswordProvider = Future<String?> Function(String fileName)` — Task 3 定义，Task 6/8/12/13 一致使用
- `PdfImage(pageIndex, extension, bytes)` — Task 6 定义，Task 12 消费 `image.extension`/`image.bytes` 一致
- `extractPdfImages(Uint8List, {passwordProvider, fileName})` — Task 6 定义，Task 7/8/9/10 调用签名一致
- `PdfSecurityHandler{fileKey, cipher, encryptMetadata}` + `decryptStream(data, objNum, objGen)` — Task 8 定义，document.dart `streamData` 调用一致；`PdfCipher.{rc4,aes128,aes256}` Task 8 定义、Task 9 复用
- `setupSecurity(doc, {passwordProvider, fileName})` — Task 8 定义，document.dart `open()` 调用一致
- 异常族：`PdfExtractException`(Task2) ← `PdfSyntaxException`(Task2)/`PdfNoImagesException`,`PdfUnsupportedEncodingException`(Task6)/`PdfEncryptedException`(Task8)；`PdfCancelledException`(Task8, 独立 implements Exception) — Task 13 `pdfErrorMessage` 与 `pdf()`/`multiplePdf()` 的 catch 类型一致
- `CBZ.comicFromCacheDir(Directory, {title, author, tags, chapters})` — Task 11 定义，Task 12 调用一致
- `LocalManager.forTesting(String)` / `debugSetInstance(LocalManager?)` — Task 11 定义，Task 11/12 测试一致
- `ImportComic.wrapPasswordProvider` / `pdfErrorMessage` / `passwordProvider` 字段 — Task 13 定义并测试一致
- `rc4/aesCbcEncryptNoPad/aesCbcDecryptNoPad/aesEcbDecryptNoPad/stripPkcs7` — Task 8 定义；`aesEcbDecryptNoPad` 目前仅 R5/R6 的 /Perms 校验会用到，Task 9 未强制调用（/Perms 校验为可选，规格 §6.2 列为"验证"而非硬性）——若实施者选择实现 /Perms 校验则复用之，否则该函数为 R6 完整性保留（不报未使用告警：Dart 对 public 顶层函数不报 unused）

> 说明：`aesEcbDecryptNoPad` 在当前 Task 8/9 代码路径中未被调用（文件密钥经 UE 直接解出，无需 /Perms）。保留它是为规格 §6.2 提到的 "/Perms 验证" 可选增强；`flutter analyze` 不会对 public 顶层函数报未使用。若实施者希望零冗余，可在 Task 9 补一段 /Perms 校验（`aesEcbDecryptNoPad(fileKey, perms)` 后检查 byte[8] 的 'T'/'F' 与 byte[9..12] 的 'adbT' 魔数）并加一条断言，或直接删除该函数——二者皆可，不影响主线。

