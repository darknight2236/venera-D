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

    // comicFromCacheDir copies bytes verbatim; only the extension matters.
    Uint8List fake() => Uint8List.fromList([1, 2, 3, 4]);

    // Each call gets its own subdirectory so several caches can coexist.
    var cacheSeq = 0;
    Directory makeCache(List<String> names) {
      final cache =
          Directory(FilePath.join(tmp.path, 'cache${cacheSeq++}'))
            ..createSync();
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

    test('numbers pages by numeric filename order, not lexicographic',
        () async {
      final cache = makeCache(['1.png', '2.png', '10.png']);

      await CBZ.comicFromCacheDir(cache, title: 'Ordered');

      final dir = Directory(FilePath.join(local.path, 'Ordered'));
      // 1.png became the cover; 2.png and 10.png are pages 1 and 2 in order.
      expect(File(FilePath.join(dir.path, 'cover.png')).existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, '1.png')).existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, '2.png')).existsSync(), isTrue);
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

      await expectLater(
        CBZ.comicFromCacheDir(cache, title: 'Dup'),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when the cache holds no supported images', () async {
      final cache = makeCache(['notes.txt']);

      await expectLater(
        CBZ.comicFromCacheDir(cache, title: 'Empty'),
        throwsA(isA<Exception>()),
      );
    });

    test('does not delete the caller cache directory', () async {
      final cache = makeCache(['1.png']);

      await CBZ.comicFromCacheDir(cache, title: 'Kept');

      // The caller owns cache cleanup; the tail must leave it in place.
      expect(cache.existsSync(), isTrue);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
