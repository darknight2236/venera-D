import 'dart:math' as math;
import 'dart:typed_data';

import 'objects.dart';

/// Inverts PNG (10-15) or TIFF (2) predictors and returns the reconstructed
/// sample bytes. Predictor 1 returns [data].
///
/// Shared by image samples and by cross-reference / object streams, which the
/// spec lets producers predictor-encode the same way.
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
