import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/opencc.dart';

bool _openCCReady = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    appdata = Appdata.forTesting();
    // The OpenCC tables are late-final; load them once for conversion tests.
    if (!_openCCReady) {
      await OpenCC.init();
      _openCCReady = true;
    }
  });

  group('ComicChapters.fromJson', () {
    test('parses a flat chapter map', () {
      var chapters = ComicChapters.fromJson({
        'ch1': '第1话',
        'ch2': '第2话',
      });

      expect(chapters.isGrouped, isFalse);
      expect(chapters.length, 2);
      expect(chapters.ids.toList(), ['ch1', 'ch2']);
      expect(chapters.titles.toList(), ['第1话', '第2话']);
      expect(chapters['ch1'], '第1话');
      expect(chapters['missing'], isNull);
    });

    test('parses grouped chapters preserving group order', () {
      var chapters = ComicChapters.fromJson({
        '组1': {'a': 'A', 'b': 'B'},
        '组2': {'c': 'C'},
      });

      expect(chapters.isGrouped, isTrue);
      expect(chapters.groups.toList(), ['组1', '组2']);
      expect(chapters.length, 3);
      expect(chapters.getGroupByIndex(0).keys.toList(), ['a', 'b']);
      expect(chapters.getGroupByIndex(1).keys.toList(), ['c']);
      expect(chapters.ids.toList(), ['a', 'b', 'c']);
    });

    test('mixed flat and grouped falls back to flat only', () {
      // Documented behavior of the current parser: when both flat and grouped
      // entries exist, only the flat ones are kept.
      var chapters = ComicChapters.fromJson({
        'ch1': '第1话',
        '组1': {'a': 'A'},
      });

      expect(chapters.isGrouped, isFalse);
      expect(chapters.length, 1);
      expect(chapters.ids.toList(), ['ch1']);
    });

    test('empty map yields an empty flat ComicChapters', () {
      var chapters = ComicChapters.fromJson({});

      expect(chapters.isGrouped, isFalse);
      expect(chapters.length, 0);
    });

    test('non-map input throws', () {
      expect(() => ComicChapters.fromJson('not-a-map'), throwsArgumentError);
      expect(() => ComicChapters.fromJson(null), throwsArgumentError);
    });

    test('fromJsonOrNull returns null for null input', () {
      expect(ComicChapters.fromJsonOrNull(null), isNull);
      expect(ComicChapters.fromJsonOrNull({'a': 'A'}), isNotNull);
    });

    test('round-trips through toJson', () {
      var original = ComicChapters.fromJson({
        'ch1': '第1话',
        'ch2': '第2话',
      });

      var restored = ComicChapters.fromJson(original.toJson());

      expect(restored.ids.toList(), ['ch1', 'ch2']);
      expect(restored.titles.toList(), ['第1话', '第2话']);
    });
  });

  group('Comic.fromJson', () {
    test('maps all fields', () {
      var comic = Comic.fromJson({
        'title': '测试漫画',
        'cover': 'https://example.com/cover.jpg',
        'id': 'c1',
        'subTitle': '副标题',
        'tags': ['tag1', 'tag2'],
        'description': '描述',
        'maxPage': 10,
        'language': 'zh-CN',
        'stars': 4.5,
      }, 'source1');

      expect(comic.title, '测试漫画');
      expect(comic.cover, 'https://example.com/cover.jpg');
      expect(comic.id, 'c1');
      expect(comic.subtitle, '副标题');
      expect(comic.tags, ['tag1', 'tag2']);
      expect(comic.description, '描述');
      expect(comic.sourceKey, 'source1');
      expect(comic.maxPage, 10);
      expect(comic.language, 'zh-CN');
      expect(comic.stars, 4.5);
    });

    test('accepts both subtitle and subTitle keys', () {
      expect(
        Comic.fromJson({'title': 't', 'cover': 'c', 'id': '1', 'subtitle': 'a'}, 's').subtitle,
        'a',
      );
      expect(
        Comic.fromJson({'title': 't', 'cover': 'c', 'id': '2', 'subTitle': 'b'}, 's').subtitle,
        'b',
      );
    });

    test('defaults missing optional fields', () {
      var comic = Comic.fromJson({'title': 't', 'cover': 'c', 'id': 'i'}, 's');

      expect(comic.subtitle, '');
      expect(comic.tags, isEmpty);
      expect(comic.description, '');
      expect(comic.maxPage, isNull);
      expect(comic.stars, isNull);
    });

    test('equality is by id and sourceKey', () {
      var a = Comic.fromJson({'title': 't', 'cover': 'c', 'id': 'x'}, 's1');
      var b = Comic.fromJson({'title': 't', 'cover': 'c', 'id': 'x'}, 's1');
      var c = Comic.fromJson({'title': 't', 'cover': 'c', 'id': 'x'}, 's2');

      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('ComicDetails.fromJson', () {
    test('parses nested chapters, comments and recommend', () {
      var details = ComicDetails.fromJson({
        'title': '详情漫画',
        'subtitle': '副标题',
        'cover': 'https://example.com/c.jpg',
        'description': '描述',
        'tags': {'题材': ['热血', '冒险']},
        'chapters': {'ch1': '第1话'},
        'sourceKey': 'src',
        'comicId': 'cid1',
        'comments': [
          {'userName': 'u1', 'content': '好看', 'id': 1, 'time': 0},
        ],
        'recommend': [
          {'title': '推荐1', 'cover': 'c', 'id': 'r1'},
        ],
        'stars': 5,
      });

      expect(details.title, '详情漫画');
      expect(details.subTitle, '副标题');
      expect(details.cover, 'https://example.com/c.jpg');
      expect(details.sourceKey, 'src');
      expect(details.comicId, 'cid1');
      expect(details.chapters, isNotNull);
      expect(details.chapters!.ids.toList(), ['ch1']);
      expect(details.comments, hasLength(1));
      expect(details.comments!.first.userName, 'u1');
      expect(details.comments!.first.content, '好看');
      expect(details.recommend, hasLength(1));
      expect(details.recommend!.first.id, 'r1');
      expect(details.stars, 5);
    });

    test('tolerates missing chapters and comments', () {
      var details = ComicDetails.fromJson({
        'title': 't',
        'cover': 'c',
        'sourceKey': 's',
        'comicId': 'i',
      });

      expect(details.chapters, isNull);
      expect(details.comments, isNull);
      expect(details.recommend, isNull);
    });
  });

  group('convertToSimplified', () {
    test('is off by default (no conversion)', () {
      var comic = Comic.fromJson({
        'title': '測試漫畫',
        'cover': 'c',
        'id': 'i',
        'description': '繁體描述',
      }, 's');

      expect(comic.title, '測試漫畫');
      expect(comic.description, '繁體描述');
    });

    test('converts title and description when enabled', () {
      appdata.settings[SettingKeys.convertToSimplified] = true;

      var comic = Comic.fromJson({
        'title': '測試漫畫',
        'cover': 'c',
        'id': 'i',
        'description': '繁體描述',
      }, 's');

      expect(comic.title, '测试漫画');
      expect(comic.description, '繁体描述');
    });

    test('converts chapter titles when enabled', () {
      appdata.settings[SettingKeys.convertToSimplified] = true;

      var chapters = ComicChapters.fromJson({'ch1': '第1話'});

      expect(chapters['ch1'], '第1话');
    });
  });
}