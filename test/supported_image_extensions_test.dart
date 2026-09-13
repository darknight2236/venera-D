import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/consts.dart';

void main() {
  group('isSupportedImageName', () {
    test('accepts every supported extension', () {
      for (final ext in supportedImageExtensions) {
        expect(isSupportedImageName('image.$ext'), isTrue, reason: ext);
      }
    });

    test('is case-insensitive (IMG.JPG used to be rejected)', () {
      expect(isSupportedImageName('IMG.JPG'), isTrue);
      expect(isSupportedImageName('photo.Png'), isTrue);
      expect(isSupportedImageName('scan.JPEG'), isTrue);
    });

    test('accepts full paths, judged by the file name', () {
      expect(isSupportedImageName(r'C:\comics\my.title\page 1.webp'), isTrue);
      expect(isSupportedImageName('/sdcard/comics/ch1/001.avif'), isTrue);
    });

    test('rejects non-image files and names without extension', () {
      expect(isSupportedImageName('notes.txt'), isFalse);
      expect(isSupportedImageName('video.mp4'), isFalse);
      expect(isSupportedImageName('LICENSE'), isFalse);
      expect(isSupportedImageName('image.'), isFalse);
    });

    test('a path whose only dot is in a directory is not an image', () {
      expect(isSupportedImageName('/home/u.d/image'), isFalse);
    });

    test('the shared list has no duplicates and covers the legacy drift', () {
      expect(supportedImageExtensions.toSet().length,
          supportedImageExtensions.length);
      // Historical drift guards: .jpe (import-only before), .avif/.bmp
      // (reader-only before) must all be present in the single list.
      expect(supportedImageExtensions, containsAll(['jpe', 'avif', 'bmp']));
    });
  });
}
