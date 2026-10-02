import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'objects.dart';

class _XrefEntry {
  /// 0 = free, 1 = uncompressed (field2 = byte offset, field3 = generation),
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
      // Offsets come from attacker-controlled integers whose intValue
      // saturates at int64-max; validate before touching the buffer.
      if (offset >= bytes.length) {
        throw PdfSyntaxException('xref offset $offset past end of file');
      }
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
    _skipObjectHeader(p);
    final obj = p.parseObject();
    if (obj is! PdfStream) {
      throw PdfSyntaxException('No xref at offset $offset');
    }
    final type = obj.dict['Type'];
    if (type is! PdfName || type.name != 'XRef') {
      throw PdfSyntaxException('No xref at offset $offset');
    }
    _readXrefStream(obj); // Task 4
    return (trailer: obj.dict, prev: _prevOf(obj.dict));
  }

  ({PdfDictionary trailer, int prev}) _parseClassicXref(PdfParser p) {
    while (true) {
      p.skipWhitespaceAndComments();
      if (p.matchKeyword('trailer')) break;
      final firstObj = _subsectionInt(p, 'first object number');
      final count = _subsectionInt(p, 'entry count');
      // An entry cannot physically fit in fewer than five bytes (three
      // one-char tokens plus two separators), so a larger count means a
      // corrupt header; this also caps hostile counts and keeps
      // firstObj + i from overflowing.
      final remaining = bytes.length - p.pos;
      if (firstObj < 0 ||
          count < 0 ||
          count > remaining ~/ 5 ||
          firstObj + count < firstObj) {
        throw PdfSyntaxException(
            'Corrupt xref subsection $firstObj $count ($remaining bytes left)');
      }
      for (var i = 0; i < count; i++) {
        // Entries are nominally 20 bytes but producers vary the EOL; reading
        // three whitespace-delimited tokens per entry tolerates all variants.
        final offText = p.readToken();
        final genText = p.readToken();
        final typeText = p.readToken();
        final field2 = int.tryParse(offText);
        final field3 = int.tryParse(genText);
        if (field2 == null || field3 == null) {
          throw PdfSyntaxException(
              'Malformed xref entry in subsection $firstObj $count');
        }
        final objNum = firstObj + i;
        if (_xref.containsKey(objNum)) continue; // newest section wins
        // Free entries are recorded too, so a deletion in a newer section
        // wins over an older 'n' entry further down the /Prev chain.
        _xref[objNum] = _XrefEntry(typeText == 'n' ? 1 : 0, field2, field3);
      }
    }
    final trailerObj = p.parseObject();
    if (trailerObj is! PdfDictionary) {
      throw const PdfSyntaxException('Malformed trailer');
    }
    return (trailer: trailerObj, prev: _prevOf(trailerObj));
  }

  int _subsectionInt(PdfParser p, String what) {
    final n = p.parseObject();
    if (n is! PdfNumber) {
      throw PdfSyntaxException('xref subsection header: $what is not a number');
    }
    return n.intValue;
  }

  /// A /Prev of the wrong type ends the chain instead of throwing a
  /// TypeError at a cast.
  static int _prevOf(PdfDictionary dict) {
    final prev = dict['Prev'];
    return prev is PdfNumber ? prev.intValue : 0;
  }

  /// Consumes the `N G obj` header. matchKeyword does not skip leading
  /// whitespace, and number parsing restores pos before the whitespace it
  /// scanned, so an explicit skip is required before 'obj'.
  void _skipObjectHeader(PdfParser p) {
    p.skipWhitespaceAndComments();
    p.parseObject(); // object number
    p.parseObject(); // generation
    p.skipWhitespaceAndComments();
    p.matchKeyword('obj');
  }

  /// Reads a PDF 1.5+ cross-reference stream. Per spec 7.5.8.2 an xref stream
  /// is never encrypted, so this reads [PdfStream.raw] directly instead of
  /// going through [streamData] (which decrypts once Task 8 lands).
  void _readXrefStream(PdfStream stream) {
    var data = stream.raw;
    final len = stream.dict['Length'];
    if (len is PdfNumber && len.value >= 0 && len.value <= data.length) {
      data = Uint8List.sublistView(data, 0, len.value.round());
    }
    data = _applyFlate(
        data, _filterNames(stream.dict['Filter']), 'xref stream');

    final wObj = stream.dict['W'];
    if (wObj is! PdfArray || wObj.items.length != 3) {
      throw const PdfSyntaxException('xref stream needs a three-field /W');
    }
    final w = <int>[];
    for (final e in wObj.items) {
      if (e is! PdfNumber) {
        throw const PdfSyntaxException('xref stream /W holds a non-number');
      }
      final field = e.intValue;
      if (field < 0 || field > 8) {
        throw PdfSyntaxException('xref stream /W field out of range: $field');
      }
      w.add(field);
    }
    final entrySize = w[0] + w[1] + w[2];
    if (entrySize == 0) {
      throw const PdfSyntaxException('Degenerate xref stream /W');
    }

    final size = (stream.dict['Size'] as PdfNumber?)?.intValue ?? 0;
    final List<int> index;
    final indexObj = stream.dict['Index'];
    if (indexObj is PdfArray) {
      index = [];
      for (final e in indexObj.items) {
        if (e is! PdfNumber) {
          throw const PdfSyntaxException(
              'xref stream /Index holds a non-number');
        }
        index.add(e.intValue);
      }
      if (index.length.isOdd) {
        throw const PdfSyntaxException('xref stream /Index needs pairs');
      }
    } else {
      index = [0, size];
    }

    // Bound the declared entry count against what the payload can physically
    // hold, so an untrusted /Index cannot drive an unbounded loop.
    var declared = 0;
    for (var s = 0; s + 1 < index.length; s += 2) {
      if (index[s] < 0 || index[s + 1] < 0) {
        throw PdfSyntaxException('xref stream /Index pair out of range');
      }
      declared += index[s + 1];
    }
    if (declared > data.length ~/ entrySize) {
      throw PdfSyntaxException('xref stream declares $declared entries but '
          'holds ${data.length ~/ entrySize}');
    }

    var cursor = 0;
    int readField(int wi) {
      if (w[wi] == 0) {
        // Spec defaults for a zero-width field: type 1, fields 0.
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
        // Type 1 = direct, 2 = compressed; anything else is a free entry,
        // recorded so a newer section's deletion shadows an older in-use
        // entry, matching the classic-table path.
        _xref[objNum] =
            _XrefEntry(type == 1 || type == 2 ? type : 0, f2, f3);
      }
    }
  }

  /// Inflates a PDF FlateDecode payload, tolerating producers that emit raw
  /// deflate without the zlib header.
  Uint8List _applyFlate(
      Uint8List data, List<String> filters, String what) {
    if (filters.isEmpty) return data;
    if (filters.length != 1 || filters.first != 'FlateDecode') {
      throw PdfSyntaxException('Unsupported $what filter ${filters.join('/')}');
    }
    return inflatePdf(data);
  }

  /// Fetches an object by number (with caching). Null when free/unknown.
  PdfObject? fetch(int objNum) {
    if (_objectCache.containsKey(objNum)) return _objectCache[objNum];
    final entry = _xref[objNum];
    PdfObject? obj;
    if (entry != null && entry.type == 1) {
      final offset = entry.field2;
      if (offset < 0 || offset >= bytes.length) {
        throw PdfSyntaxException(
            'Object $objNum: xref offset $offset outside the file');
      }
      final p = PdfParser(bytes, offset);
      _skipObjectHeader(p);
      obj = p.parseObject();
      if (obj is PdfStream) {
        obj.objNum = objNum;
        obj.objGen = entry.field3;
      }
    } else if (entry != null && entry.type == 2) {
      obj = _fetchFromObjStm(entry.field2, entry.field3);
    }
    _objectCache[objNum] = obj;
    return obj;
  }

  /// Extracts one object from a compressed object stream (cached per stream).
  PdfObject? _fetchFromObjStm(int stmNum, int index) {
    var cached = _objStmCache[stmNum];
    if (cached == null) {
      // An object stream must itself be a direct object; refusing anything
      // else is what keeps a corrupt file from recursing through fetch().
      final stmEntry = _xref[stmNum];
      if (stmEntry == null || stmEntry.type != 1) {
        throw PdfSyntaxException('Object stream $stmNum is not a direct object');
      }
      final stm = fetch(stmNum);
      if (stm is! PdfStream) {
        throw PdfSyntaxException('Object stream $stmNum is not a stream');
      }
      final data = _applyFlate(
          streamData(stm), _filterNames(stm.dict['Filter']), 'object stream');
      final n = (stm.dict['N'] as PdfNumber?)?.intValue ?? 0;
      final first = (stm.dict['First'] as PdfNumber?)?.intValue ?? 0;
      // Each header pair costs at least four bytes, so an untrusted /N larger
      // than that is corruption, not a request to allocate.
      if (n < 0 || first < 0 || n > data.length ~/ 4 || first > data.length) {
        throw PdfSyntaxException('Malformed object stream $stmNum '
            '(/N $n, /First $first, ${data.length} bytes of data)');
      }
      final header = PdfParser(data, 0);
      final nums = <int>[];
      final offs = <int>[];
      for (var i = 0; i < n; i++) {
        final numObj = header.parseObject();
        final offObj = header.parseObject();
        if (numObj is! PdfNumber || offObj is! PdfNumber) {
          throw PdfSyntaxException('Malformed header in object stream $stmNum');
        }
        nums.add(numObj.intValue);
        offs.add(offObj.intValue);
      }
      final objects = List<PdfObject?>.filled(n, null);
      for (var i = 0; i < n; i++) {
        final start = first + offs[i];
        if (start < first || start > data.length) {
          throw PdfSyntaxException('Object stream $stmNum entry $i starts at '
              '$start, outside its ${data.length} bytes of data');
        }
        objects[i] = PdfParser(data, start).parseObject();
      }
      cached = (nums: nums, objects: objects);
      _objStmCache[stmNum] = cached;
    }
    if (index < 0 || index >= cached.objects.length) {
      throw PdfSyntaxException(
          'Index $index out of range in object stream $stmNum');
    }
    return cached.objects[index];
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

  /// The name of [obj] if it resolves to a name, otherwise null. A corrupt
  /// type entry must degrade to "unknown" rather than crash on a cast.
  String? _nameOf(PdfObject? obj) {
    final r = resolve(obj);
    return r is PdfName ? r.name : null;
  }

  /// Leaf pages in reading order, each paired with its effective /Resources
  /// (page-level value wins; otherwise inherited from ancestor Pages nodes,
  /// per spec 7.7.3.3).
  List<({PdfDictionary page, PdfObject? resources})> pages() {
    final root = resolveDict(trailer['Root']);
    final pagesRoot = resolveDict(root['Pages']);
    final result = <({PdfDictionary page, PdfObject? resources})>[];
    void walk(PdfDictionary node, PdfObject? inherited, int depth) {
      if (depth > 64) {
        throw const PdfSyntaxException('Page tree too deep (cycle?)');
      }
      final resources = node['Resources'] ?? inherited;
      final kids = resolve(node['Kids']);
      if (_nameOf(node['Type']) == 'Page' || kids is! PdfArray) {
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
      if (obj is PdfStream && _nameOf(obj.dict['Subtype']) == 'Image') {
        result.add(obj);
      }
    }
    return result;
  }

  /// Raw stream bytes honoring an indirect /Length, and (from Task 8)
  /// transport decryption.
  Uint8List streamData(PdfStream stream) {    final len = resolve(stream.dict['Length']);
    var raw = stream.raw;
    if (len is PdfNumber && len.intValue >= 0 && len.intValue <= raw.length) {
      raw = Uint8List.sublistView(raw, 0, len.intValue);
    }
    return raw;
  }
}

/// The /Filter chain of a stream as names, empty when it declares none.
/// PDF permits either a bare name or an array of names.
List<String> _filterNames(PdfObject? filter) {
  if (filter == null) return const [];
  if (filter is PdfName) return [filter.name];
  if (filter is PdfArray) {
    return [
      for (final e in filter.items)
        e is PdfName
            ? e.name
            : (throw const PdfSyntaxException('Non-name /Filter entry'))
    ];
  }
  throw const PdfSyntaxException('Unrecognized stream /Filter');
}

/// The raw-deflate decoder, reused so the fallback path allocates no codec.
final _rawInflate = ZLibDecoder(raw: true);

/// Inflates a PDF FlateDecode payload. Tolerates producers that omit the
/// zlib header (raw deflate).
Uint8List inflatePdf(Uint8List data) {
  try {
    return Uint8List.fromList(zlib.decode(data));
  } on FormatException {
    try {
      return Uint8List.fromList(_rawInflate.convert(data));
    } on FormatException {
      throw const PdfSyntaxException('Corrupt FlateDecode data');
    }
  }
}
