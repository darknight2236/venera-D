import 'dart:convert';
import 'dart:typed_data';

/// Base class of the PDF object model. Instances are produced by [PdfParser].
abstract class PdfObject {
  const PdfObject();
}

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
/// per call starting at [pos].
///
/// `pos` advances past what was consumed, with one exception: after a stream
/// it stops at the end of the stream *data*, before the trailing EOL and the
/// `endstream` keyword. Callers locate objects by byte offset instead of
/// reading sequentially, so nothing depends on `pos` reaching past
/// `endstream`.
class PdfParser {
  PdfParser(this.bytes, this.pos);

  final Uint8List bytes;
  int pos;

  /// Bounds lexical nesting: unbounded recursion overruns the stack, and
  /// StackOverflowError is not an Exception, so callers cannot catch it.
  /// Matches the cap on indirect-reference chains.
  static const int _maxDepth = 32;
  int _depth = 0;

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
    if (!_atKeyword(pos, kw)) return false;
    final after = pos + kw.length;
    if (after < bytes.length) {
      final c = bytes[after];
      if (!isWhitespace(c) && !isDelimiter(c)) return false;
    }
    pos = after;
    return true;
  }

  /// Byte comparison against [kw] at [at], without moving [pos] and without
  /// requiring a delimiter after the keyword.
  bool _atKeyword(int at, String kw) {
    if (at + kw.length > bytes.length) return false;
    for (var i = 0; i < kw.length; i++) {
      if (bytes[at + i] != kw.codeUnitAt(i)) return false;
    }
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
    if (_depth >= _maxDepth) {
      throw const PdfSyntaxException('Nesting too deep');
    }
    _depth++;
    try {
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
    } finally {
      _depth--;
    }
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
    // A few hundred digits overflow the double to Infinity, whose intValue
    // throws UnsupportedError — not an Exception, so callers cannot catch it.
    if (!value.isFinite) {
      throw PdfSyntaxException('Numeric literal out of range at offset $start');
    }
    // Indirect-reference lookahead: integer, generation, 'R'.
    if (!text.contains('.') && value == value.roundToDouble()) {
      final saved = pos;
      skipWhitespaceAndComments();
      final genStart = pos;
      while (pos < bytes.length && bytes[pos] >= 0x30 && bytes[pos] <= 0x39) {
        pos++;
      }
      // A generation number is a small non-negative integer; a longer run is
      // not a reference, and int.parse on it throws FormatException.
      final genLen = pos - genStart;
      if (genLen > 0 && genLen <= 9) {
        final gen = int.parse(latin1.decode(bytes.sublist(genStart, pos)));
        skipWhitespaceAndComments();
        if (matchKeyword('R')) {
          return PdfRef(value.toInt(), gen);
        }
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
    // Callers record pos as an object-end offset, so it must stay <= length.
    if (pos >= bytes.length) {
      throw const PdfSyntaxException('Unterminated hex string');
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
      // Bounds-check in double space: intValue saturates at int64-max for a
      // huge /Length, and dataStart plus that wraps negative straight through
      // an integer comparison.
      if (length is PdfNumber &&
          length.value >= 0 &&
          length.value <= bytes.length - dataStart) {
        final candidate = dataStart + length.value.round();
        // A stale but in-bounds /Length silently truncates the stream, so
        // require the endstream keyword that has to follow the data.
        final verified = _endstreamFollows(candidate);
        dataEnd = verified ? candidate : _findEndstream(dataStart);
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

  /// True when `endstream` starts at [at], allowing the single EOL that
  /// ISO 32000 puts between the stream data and the keyword — some producers
  /// omit it.
  bool _endstreamFollows(int at) {
    var i = at;
    if (i >= bytes.length) return false;
    if (bytes[i] == 0x0D) {
      i++;
      if (i < bytes.length && bytes[i] == 0x0A) i++;
    } else if (bytes[i] == 0x0A) {
      i++;
    }
    return _atKeyword(i, 'endstream');
  }

  int _findEndstream(int from) {
    for (var i = from; i + 9 <= bytes.length; i++) {
      if (bytes[i] == 0x65 && _atKeyword(i, 'endstream')) {
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

/// Called when an encrypted PDF needs a user password. The returned string
/// is tried; returning null means the user cancelled.
typedef PdfPasswordProvider = Future<String?> Function(String fileName);
