import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';

void main() {
  group('ImageFavoritesProvider.getImageFromLocal (file:// keys, #513)', () {
    late Directory tempDir;

    ImageFavoritesProvider providerFor(String imageKey) {
      return ImageFavoritesProvider(
        ImageFavorite(
          3,
          imageKey,
          null,
          'eid1',
          'cid1',
          1,
          'testsource',
          'Chapter 1',
        ),
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_imgfav_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns the bytes of an existing downloaded image', () async {
      final file = File('${tempDir.path}/page.jpg');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await file.writeAsBytes(bytes);

      final result =
          await providerFor('file://${file.path}').getImageFromLocal();

      expect(result, bytes);
    });

    test('returns null when the downloaded file was deleted', () async {
      // The caller then resolves a fresh network key from the source,
      // instead of crashing on the dead path.
      final result = await providerFor(
        'file://${tempDir.path}/missing.jpg',
      ).getImageFromLocal();

      expect(result, isNull);
    });

    test('returns null for an empty file', () async {
      final file = File('${tempDir.path}/empty.jpg');
      await file.create();

      final result =
          await providerFor('file://${file.path}').getImageFromLocal();

      expect(result, isNull);
    });
  });
}
