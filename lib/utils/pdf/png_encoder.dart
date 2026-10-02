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
