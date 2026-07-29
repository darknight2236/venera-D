import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';

import 'helpers/sqlite3_test_setup.dart';

ImageFavorite _image(String comicId, int ep, int page,
    {String sourceKey = 'src'}) {
  return ImageFavorite(
    page,
    'imageKey-$comicId-$ep-$page',
    null,
    'eid$ep',
    comicId,
    ep,
    sourceKey,
    'Episode $ep',
  );
}

ImageFavoritesComic _comic(
  String id, {
  String title = 'Title',
  String sourceKey = 'src',
  List<ImageFavoritesEp>? eps,
}) {
  return ImageFavoritesComic(
    id,
    eps ?? [],
    title,
    sourceKey,
    ['tag1', 'tag2'],
    ['标签1'],
    DateTime(2026, 1, 1),
    'Author',
    {},
    'SubTitle',
    30,
  );
}

ImageFavoritesEp _ep(String comicId, int ep, List<int> pages) {
  return ImageFavoritesEp(
    'eid$ep',
    ep,
    pages.map((p) => _image(comicId, ep, p)).toList(),
    'Episode $ep',
    10,
  );
}

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('ImageFavoriteManager', () {
    late HistoryManager host;
    late ImageFavoriteManager manager;
    late Directory tempDir;

    setUp(() {
      // deleteImageFavorite resolves cached image files under App.cachePath.
      tempDir = Directory.systemTemp.createTempSync('venera_img_fav_test');
      App.cachePath = tempDir.path;
      host = HistoryManager.forTesting();
      manager = ImageFavoriteManager.forTesting(host);
      addTearDown(() {
        host.close();
        tempDir.deleteSync(recursive: true);
      });
    });

    test('starts empty', () {
      expect(manager.length, 0);
      expect(manager.getAll(), isEmpty);
    });

    test('addOrUpdateOrDelete + find round-trips a comic', () {
      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        _ep('c1', 1, [1, 3]),
      ]));

      final found = manager.find('c1', 'src');

      expect(found, isNotNull);
      expect(found!.title, 'Title');
      expect(found.subTitle, 'SubTitle');
      expect(found.author, 'Author');
      expect(found.tags, ['tag1', 'tag2']);
      expect(found.imageFavoritesEp, hasLength(1));
      expect(found.imageFavoritesEp.first.imageFavorites.map((e) => e.page),
          [1, 3]);
    });

    test('deduplicates episodes and pages, sorted ascending', () {
      final dupEp = _ep('c1', 2, [5, 5, 3]);
      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        dupEp,
        _ep('c1', 2, [9]), // duplicate ep, should be dropped
        _ep('c1', 1, [2]),
      ]));

      final found = manager.find('c1', 'src')!;

      expect(found.imageFavoritesEp.map((e) => e.ep), [1, 2]);
      expect(
        found.imageFavoritesEp.last.imageFavorites.map((e) => e.page),
        [3, 5],
      );
    });

    test('empty episode list deletes the stored comic', () {
      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        _ep('c1', 1, [1]),
      ]));
      expect(manager.length, 1);

      manager.addOrUpdateOrDelete(_comic('c1'));

      expect(manager.length, 0);
      expect(manager.find('c1', 'src'), isNull);
    });

    test('has reflects stored pages', () {
      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        _ep('c1', 1, [4]),
      ]));

      expect(manager.has('c1', 'src', 'eid1', 4, 1), isTrue);
      expect(manager.has('c1', 'src', 'eid1', 5, 1), isFalse);
      expect(manager.has('c2', 'src', 'eid1', 4, 1), isFalse);
    });

    test('search matches title keyword', () {
      manager.addOrUpdateOrDelete(_comic('c1', title: 'Alpha', eps: [
        _ep('c1', 1, [1]),
      ]));
      manager.addOrUpdateOrDelete(_comic('c2', title: 'Beta', eps: [
        _ep('c2', 1, [1]),
      ]));

      expect(manager.search('Alph').map((c) => c.id), ['c1']);
      expect(manager.search(''), isEmpty);
    });

    test('deleteImageFavorite removes images and empty comics', () {
      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        _ep('c1', 1, [1, 2]),
      ]));

      manager.deleteImageFavorite([_image('c1', 1, 1)]);
      expect(
        manager.find('c1', 'src')!.imageFavoritesEp.first.imageFavorites,
        hasLength(1),
      );

      manager.deleteImageFavorite([_image('c1', 1, 2)]);
      expect(manager.find('c1', 'src'), isNull);
    });

    test('addOrUpdateOrDelete notifies listeners', () {
      var notified = 0;
      manager.addListener(() => notified++);

      manager.addOrUpdateOrDelete(_comic('c1', eps: [
        _ep('c1', 1, [1]),
      ]));

      expect(notified, 1);
    });

    test('debugSetInstance overrides the factory singleton', () {
      final injected = ImageFavoriteManager.forTesting(host);
      addTearDown(() => ImageFavoriteManager.debugSetInstance(null));

      ImageFavoriteManager.debugSetInstance(injected);

      expect(identical(ImageFavoriteManager(), injected), isTrue);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
