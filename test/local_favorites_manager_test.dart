import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';

import 'helpers/sqlite3_test_setup.dart';

FavoriteItem _stubItem(String id, {int typeValue = 0, List<String>? tags}) {
  return FavoriteItem(
    id: id,
    name: 'Name $id',
    coverPath: 'https://example.com/$id.jpg',
    author: 'Author $id',
    type: ComicType(typeValue),
    tags: tags ?? ['tag1', 'tag2'],
    favoriteTime: DateTime(2026, 1, 1),
  );
}

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('LocalFavoritesManager', () {
    late LocalFavoritesManager manager;
    late Directory tempDir;

    setUp(() {
      // addComic reads settings; cover deletion resolves under App.dataPath.
      appdata = Appdata.forTesting();
      tempDir = Directory.systemTemp.createTempSync('venera_fav_test');
      App.dataPath = tempDir.path;
      manager = LocalFavoritesManager.forTesting();
      addTearDown(() {
        manager.close();
        tempDir.deleteSync(recursive: true);
      });
    });

    test('starts with no folders', () {
      expect(manager.folderNames, isEmpty);
      expect(manager.totalComics, 0);
    });

    test('createFolder makes the folder visible', () {
      manager.createFolder('fav');

      expect(manager.existsFolder('fav'), isTrue);
      expect(manager.folderNames, ['fav']);
      expect(manager.count('fav'), 0);
    });

    test('createFolder rejects duplicates and empty names', () {
      manager.createFolder('fav');

      expect(() => manager.createFolder('fav'), throwsException);
      expect(() => manager.createFolder(''), throwsA(anything));
    });

    test('createFolder with renameWhenInvalidName picks a fresh name', () {
      manager.createFolder('fav');

      final actual = manager.createFolder('fav', true);

      expect(actual, isNot('fav'));
      expect(manager.existsFolder(actual), isTrue);
    });

    test('addComic + getFolderComics round-trips fields', () {
      manager.createFolder('fav');

      final added = manager.addComic('fav', _stubItem('c1'));
      final comics = manager.getFolderComics('fav');

      expect(added, isTrue);
      expect(comics, hasLength(1));
      expect(comics.first.id, 'c1');
      expect(comics.first.name, 'Name c1');
      expect(comics.first.author, 'Author c1');
      expect(comics.first.coverPath, 'https://example.com/c1.jpg');
      expect(comics.first.tags, ['tag1', 'tag2']);
      expect(manager.count('fav'), 1);
      expect(manager.folderComics('fav'), 1);
    });

    test('addComic refuses duplicates in the same folder', () {
      manager.createFolder('fav');
      manager.addComic('fav', _stubItem('c1'));

      expect(manager.addComic('fav', _stubItem('c1')), isFalse);
      expect(manager.count('fav'), 1);
    });

    test('addComic to unknown folder throws', () {
      expect(() => manager.addComic('missing', _stubItem('c1')),
          throwsException);
    });

    test('isExist reflects additions and deletions', () {
      manager.createFolder('fav');
      manager.addComic('fav', _stubItem('c1'));

      expect(manager.isExist('c1', ComicType(0)), isTrue);

      manager.deleteComicWithId('fav', 'c1', ComicType(0));

      expect(manager.isExist('c1', ComicType(0)), isFalse);
      expect(manager.count('fav'), 0);
    });

    test('find returns folders containing the comic', () {
      manager.createFolder('a');
      manager.createFolder('b');
      manager.addComic('a', _stubItem('c1'));
      manager.addComic('b', _stubItem('c1'));

      expect(manager.find('c1', ComicType(0)), containsAll(['a', 'b']));
      expect(manager.find('other', ComicType(0)), isEmpty);
    });

    test('deleteFolder removes the folder and its comics', () {
      manager.createFolder('fav');
      manager.addComic('fav', _stubItem('c1'));

      manager.deleteFolder('fav');

      expect(manager.existsFolder('fav'), isFalse);
      expect(manager.isExist('c1', ComicType(0)), isFalse);
    });

    test('rename keeps comics and counts', () {
      manager.createFolder('before');
      manager.addComic('before', _stubItem('c1'));

      manager.rename('before', 'after');

      expect(manager.existsFolder('before'), isFalse);
      expect(manager.existsFolder('after'), isTrue);
      expect(manager.getFolderComics('after').single.id, 'c1');
      expect(manager.folderComics('after'), 1);
    });

    test('updateOrder controls folderNames ordering', () {
      manager.createFolder('a');
      manager.createFolder('b');
      manager.createFolder('c');

      manager.updateOrder(['c', 'a', 'b']);

      expect(manager.folderNames, ['c', 'a', 'b']);
    });

    test('addComic notifies listeners', () {
      manager.createFolder('fav');
      var notified = 0;
      manager.addListener(() => notified++);

      manager.addComic('fav', _stubItem('c1'));

      expect(notified, 1);
    });

    test('debugSetInstance overrides the factory singleton', () {
      final injected = LocalFavoritesManager.forTesting();
      addTearDown(() => LocalFavoritesManager.debugSetInstance(null));

      LocalFavoritesManager.debugSetInstance(injected);

      expect(identical(LocalFavoritesManager(), injected), isTrue);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
