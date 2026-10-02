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
  Uint8List finishClassic(
      {required int rootObj, String extraTrailerEntries = ''}) {
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
      '/ColorSpace /${p.colorSpace} /BitsPerComponent ${p.bpc} '
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
