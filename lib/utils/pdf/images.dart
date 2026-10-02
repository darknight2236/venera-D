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

  final width = _intValue(doc, dict['Width']);
  final height = _intValue(doc, dict['Height']);
  if (width == null || height == null || width <= 0 || height <= 0) {
    throw PdfExtractException('Page $humanPage: image without valid dimensions');
  }
  var bpc = _intValue(doc, dict['BitsPerComponent']) ?? 8;

  // Resolve the color space to a device space name, expanding /Indexed and
  // mapping /ICCBased by component count.
  var samples = data;
  var csName = 'DeviceRGB';
  final csObj = doc.resolve(dict['ColorSpace']);
  if (csObj is PdfArray && csObj.items.isNotEmpty) {
    final family = _nameOf(doc, csObj.items[0]);
    if (family == 'Indexed') {
      if (csObj.items.length < 4) {
        throw PdfExtractException(
            'Page $humanPage: malformed /Indexed color space');
      }
      final lookup = doc.resolve(csObj.items[3]);
      Uint8List table;
      if (lookup is PdfString) {
        table = lookup.bytes;
      } else if (lookup is PdfStream) {
        table = inflateIfFlate(doc, lookup);
      } else {
        throw PdfExtractException('Page $humanPage: bad /Indexed lookup');
      }
      final baseName = deviceNameFor(doc, csObj.items[1], humanPage);
      final baseChannels = channelsFor(baseName);
      samples = expandIndexed(samples, table, baseChannels);
      csName = baseName;
      // Lookup-table entries are base-space samples at the table's own bpc;
      // comic PDFs use 8-bit bases (hival <= 255).
      bpc = 8;
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
    final predictor = _intValue(doc, flateParms['Predictor']) ?? 1;
    final colors =
        _intValue(doc, flateParms['Colors']) ?? channelsFor(csName);
    final parmsBpc = _intValue(doc, flateParms['BitsPerComponent']) ?? bpc;
    final columns = _intValue(doc, flateParms['Columns']) ?? width;
    samples = applyPredictorInverse(samples,
        predictor: predictor, columns: columns, colors: colors, bpc: parmsBpc);
  }

  final decode = _decodeArray(doc, dict['Decode']);

  final rgb = toRgb8(samples, csName, width, height, decode: decode, bpc: bpc);
  return PdfImage(
    humanPage - 1,
    'png',
    encodePng(width: width, height: height, channels: 3, samples: rgb),
  );
}

/// Reads an entry as an integer, tolerating a missing or wrong-typed value.
///
/// Casts like `resolve(x) as PdfNumber?` throw a raw TypeError when a broken
/// file stores a string or array where a number is expected; that would
/// escape the PdfExtractException contract the import UI relies on.
int? _intValue(PdfDocument doc, PdfObject? obj) {
  final r = doc.resolve(obj);
  return r is PdfNumber ? r.intValue : null;
}

String? _nameOf(PdfDocument doc, PdfObject? obj) {
  final r = doc.resolve(obj);
  return r is PdfName ? r.name : null;
}

bool _boolOf(PdfDocument doc, PdfObject? obj) {
  final r = doc.resolve(obj);
  return r is PdfBool && r.value;
}

/// The image dictionary's /Decode array as doubles, or null when absent.
List<double>? _decodeArray(PdfDocument doc, PdfObject? obj) {
  final r = doc.resolve(obj);
  if (r is! PdfArray) return null;
  final out = <double>[];
  for (final e in r.items) {
    final v = doc.resolve(e);
    if (v is! PdfNumber) {
      throw const PdfExtractException('Non-numeric /Decode entry');
    }
    out.add(v.value);
  }
  return out;
}

Uint8List inflateIfFlate(PdfDocument doc, PdfStream stream) {
  var data = doc.streamData(stream);
  final filter = doc.resolve(stream.dict['Filter']);
  if (filter is PdfName && filter.name == 'FlateDecode') {
    data = inflatePdf(data);
  }
  return data;
}

/// Maps a color-space object (name or `[/ICCBased <stream>]` /
/// `[/Indexed <base> ...]` array) to a device space name we can convert from.
String deviceNameFor(PdfDocument doc, PdfObject? cs, int humanPage) {
  final resolved = doc.resolve(cs);
  if (resolved is PdfName) {
    return resolved.name;
  }
  if (resolved is PdfArray && resolved.items.length >= 2) {
    final family = _nameOf(doc, resolved.items[0]);
    if (family == 'ICCBased') {
      // The ICC profile is a stream; /N lives in its dictionary.
      final profile = doc.resolve(resolved.items[1]);
      final PdfDictionary dict;
      if (profile is PdfStream) {
        dict = profile.dict;
      } else if (profile is PdfDictionary) {
        dict = profile;
      } else {
        throw PdfUnsupportedEncodingException(humanPage, 'ICCBased profile');
      }
      final n = _intValue(doc, dict['N']) ?? 3;
      return switch (n) {
        1 => 'DeviceGray',
        3 => 'DeviceRGB',
        4 => 'DeviceCMYK',
        _ => throw PdfUnsupportedEncodingException(humanPage, 'ICCBased N=$n'),
      };
    }
    if (family == 'Indexed') {
      return deviceNameFor(doc, resolved.items[1], humanPage);
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

/// Inverts PNG (10-15) or TIFF (2) predictors and returns the reconstructed
/// sample bytes. Predictor 1 returns [data].
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
          if (i + 1 >= rowBytes) continue;
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
        if (lineStart + x >= data.length) break;
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
  if (width <= 0 || height <= 0) {
    throw PdfExtractException('Image with non-positive dimensions');
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
