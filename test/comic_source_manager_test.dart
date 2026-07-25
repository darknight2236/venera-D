import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

/// Creates a minimal [ComicSource] stub for unit tests.
///
/// Only [name], [key], and [version] are meaningful for the manager's
/// pure-logic methods; all other fields are set to safe defaults/null.
ComicSource _stubSource({
  required String name,
  required String key,
  String version = '1.0.0',
}) {
  return ComicSource(
    name,
    key,
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData
    const [], // explorePages
    null, // searchPageData
    null, // settings
    null, // loadComicInfo
    null, // loadComicThumbnail
    null, // loadComicPages
    null, // getImageLoadingConfig
    null, // getThumbnailLoadingConfig
    '/fake/path/$key.js', // filePath
    'https://example.com/$key', // url
    version,
    null, // commentsLoader
    null, // sendCommentFunc
    null, // chapterCommentsLoader
    null, // sendChapterCommentFunc
    null, // likeOrUnlikeComic
    null, // voteCommentFunc
    null, // likeCommentFunc
    null, // idMatcher
    null, // translations
    null, // handleClickTagEvent
    null, // onTagSuggestionSelected
    null, // linkHandler
    false, // enableTagsSuggestions
    false, // enableTagsTranslate
    null, // starRatingFunc
    null, // archiveDownloader
  );
}

void main() {
  group('compareSemVer', () {
    test('returns true when ver1 > ver2 (major)', () {
      expect(compareSemVer('2.0.0', '1.0.0'), isTrue);
    });

    test('returns true when ver1 > ver2 (minor)', () {
      expect(compareSemVer('1.2.0', '1.1.0'), isTrue);
    });

    test('returns true when ver1 > ver2 (patch)', () {
      expect(compareSemVer('1.0.2', '1.0.1'), isTrue);
    });

    test('returns false when ver1 == ver2', () {
      expect(compareSemVer('1.2.3', '1.2.3'), isFalse);
    });

    test('returns false when ver1 < ver2', () {
      expect(compareSemVer('1.0.0', '2.0.0'), isFalse);
    });

    test('handles pre-release dash separator', () {
      // "1.0.0-1" → "1.0.0.1"; compared against "1.0.0" → "1.0.0"
      // ver1 has a 4th segment "1" which is not "hotfix" and ver2 has none,
      // so ver1 < ver2 per the logic (ver2 null means ver1 is pre-release).
      expect(compareSemVer('1.0.0-1', '1.0.0'), isFalse);
    });

    test('hotfix is greater than base version', () {
      // "1.0.0-hotfix" → 4th segment "hotfix"; ver2 has no 4th → ver1 > ver2
      expect(compareSemVer('1.0.0-hotfix', '1.0.0'), isTrue);
    });

    test('base version is greater than non-hotfix pre-release', () {
      // ver1 "1.0.0" has no 4th segment, ver2 "1.0.0-beta" has "beta" (not "hotfix")
      // → ver1 > ver2
      expect(compareSemVer('1.0.0', '1.0.0-beta'), isTrue);
    });
  });

  group('ComicSourceManager pure logic', () {
    late ComicSourceManager manager;

    setUp(() {
      manager = ComicSourceManager.forTesting();
    });

    test('starts empty', () {
      expect(manager.isEmpty, isTrue);
      expect(manager.all(), isEmpty);
    });

    test('add() inserts a source and notifies listeners', () {
      var notified = false;
      manager.addListener(() => notified = true);

      final source = _stubSource(name: 'Test', key: 'test-src');
      manager.add(source);

      expect(manager.isEmpty, isFalse);
      expect(manager.all(), hasLength(1));
      expect(notified, isTrue);
    });

    test('find() returns source by key', () {
      final src1 = _stubSource(name: 'Alpha', key: 'alpha');
      final src2 = _stubSource(name: 'Beta', key: 'beta');
      manager.add(src1);
      manager.add(src2);

      expect(manager.find('beta'), same(src2));
      expect(manager.find('gamma'), isNull);
    });

    test('fromIntKey() returns source by hashCode of key', () {
      final src = _stubSource(name: 'Gamma', key: 'gamma');
      manager.add(src);

      expect(manager.fromIntKey('gamma'.hashCode), same(src));
      expect(manager.fromIntKey(999999), isNull);
    });

    test('remove() deletes source by key and notifies', () {
      var notifyCount = 0;
      manager.addListener(() => notifyCount++);

      manager.add(_stubSource(name: 'A', key: 'a'));
      manager.add(_stubSource(name: 'B', key: 'b'));
      notifyCount = 0; // reset after add notifications

      manager.remove('a');

      expect(manager.all(), hasLength(1));
      expect(manager.find('a'), isNull);
      expect(manager.find('b'), isNotNull);
      expect(notifyCount, 1);
    });

    test('all() returns a defensive copy', () {
      manager.add(_stubSource(name: 'X', key: 'x'));
      final list = manager.all();
      list.clear(); // modifying the copy should not affect manager

      expect(manager.all(), hasLength(1));
    });

    test('updateAvailableUpdates() merges updates and notifies', () {
      var notified = false;
      manager.addListener(() => notified = true);

      manager.updateAvailableUpdates({'src-a': '2.0.0', 'src-b': '1.1.0'});

      expect(manager.availableUpdates, {'src-a': '2.0.0', 'src-b': '1.1.0'});
      expect(notified, isTrue);
    });

    test('availableUpdates returns a defensive copy', () {
      manager.updateAvailableUpdates({'k': '1.0.0'});
      final copy = manager.availableUpdates;
      copy['k'] = '9.9.9';

      expect(manager.availableUpdates['k'], '1.0.0');
    });
  });

  group('comicSourceManager global seam', () {
    test('singleton can be replaced for testing', () {
      final fake = ComicSourceManager.forTesting();
      fake.add(_stubSource(name: 'Fake', key: 'fake'));
      comicSourceManager = fake;
      addTearDown(() => comicSourceManager = ComicSourceManager.forTesting());

      // The factory constructor now returns our fake.
      expect(ComicSourceManager().find('fake'), isNotNull);
      expect(identical(ComicSourceManager(), fake), isTrue);
    });
  });
}
