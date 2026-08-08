import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

import 'helpers/sqlite3_test_setup.dart';

/// Minimal [HistoryMixin] for exercising [History.fromModel].
class _StubModel with HistoryMixin {
  @override
  String get title => '测试漫画';

  @override
  String? get subTitle => '副标题';

  @override
  String get cover => 'https://example.com/c.jpg';

  @override
  String get id => 'comic1';

  @override
  HistoryType get historyType => ComicType(1234);
}

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('History data correctness', () {
    group('fromMap', () {
      test('restores all fields', () {
        var history = History.fromMap({
          'type': 1234,
          'time': 1750000000000,
          'title': '标题',
          'subtitle': '副标题',
          'cover': 'c.jpg',
          'ep': 3,
          'page': 7,
          'id': 'cid',
          'readEpisode': ['1', '2', '3'],
          'max_page': 20,
        });

        expect(history.type, ComicType(1234));
        expect(history.time.millisecondsSinceEpoch, 1750000000000);
        expect(history.title, '标题');
        expect(history.subtitle, '副标题');
        expect(history.cover, 'c.jpg');
        expect(history.ep, 3);
        expect(history.page, 7);
        expect(history.id, 'cid');
        expect(history.readEpisode, {'1', '2', '3'});
        expect(history.maxPage, 20);
      });

      test('defaults readEpisode to empty set when missing', () {
        var history = History.fromMap({
          'type': 1234,
          'time': 0,
          'title': 't',
          'subtitle': 's',
          'cover': 'c',
          'ep': 1,
          'page': 1,
          'id': 'i',
        });

        expect(history.readEpisode, isEmpty);
      });
    });

    group('fromRow', () {
      late Database db;

      setUp(() {
        db = sqlite3.openInMemory();
        db.execute('''
          create table history (
            id text primary key, title text, subtitle text, cover text,
            time int, type int, ep int, page int, readEpisode text,
            max_page int, chapter_group int
          );
        ''');
      });

      tearDown(() => db.dispose());

      test('restores row including comma-joined readEpisode', () {
        db.execute(
          'insert into history values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['cid', '标题', '副标题', 'c.jpg', 1750000000000, 1234, 3, 7,
              '1,2,3', 20, 2],
        );
        var row = db.select('select * from history').first;

        var history = History.fromRow(row);

        expect(history.id, 'cid');
        expect(history.title, '标题');
        expect(history.subtitle, '副标题');
        expect(history.cover, 'c.jpg');
        expect(history.time.millisecondsSinceEpoch, 1750000000000);
        expect(history.type, ComicType(1234));
        expect(history.ep, 3);
        expect(history.page, 7);
        expect(history.readEpisode, {'1', '2', '3'});
        expect(history.maxPage, 20);
        expect(history.group, 2);
      });

      test('empty readEpisode column yields empty set', () {
        db.execute(
          'insert into history values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['cid', 't', 's', 'c', 0, 1234, 1, 1, '', 10, null],
        );
        var row = db.select('select * from history').first;

        expect(History.fromRow(row).readEpisode, isEmpty);
        expect(History.fromRow(row).group, isNull);
      });
    });

    group('fromModel', () {
      test('inherits model fields and keeps passed progress', () {
        var history = History.fromModel(
          model: _StubModel(),
          ep: 2,
          page: 5,
          readChapters: {'1', '2'},
        );

        expect(history.type, ComicType(1234));
        expect(history.title, '测试漫画');
        expect(history.subtitle, '副标题');
        expect(history.cover, 'https://example.com/c.jpg');
        expect(history.id, 'comic1');
        expect(history.ep, 2);
        expect(history.page, 5);
        expect(history.readEpisode, {'1', '2'});
      });

      test('defaults readEpisode to empty set', () {
        var history = History.fromModel(model: _StubModel(), ep: 1, page: 1);

        expect(history.readEpisode, isEmpty);
      });
    });

    test('equality is by type and id', () {
      var a = History.fromMap({'type': 1, 'time': 0, 'title': 't',
          'subtitle': '', 'cover': 'c', 'ep': 1, 'page': 1, 'id': 'x'});
      var b = History.fromMap({'type': 1, 'time': 999, 'title': '不同标题',
          'subtitle': '', 'cover': 'c', 'ep': 2, 'page': 2, 'id': 'x'});
      var c = History.fromMap({'type': 2, 'time': 0, 'title': 't',
          'subtitle': '', 'cover': 'c', 'ep': 1, 'page': 1, 'id': 'x'});

      expect(a == b, isTrue); // same type+id, different progress => equal
      expect(a == c, isFalse);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}