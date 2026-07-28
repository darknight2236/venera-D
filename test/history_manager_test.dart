import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

import 'helpers/sqlite3_test_setup.dart';

History _stubHistory(
  String id, {
  int typeValue = 0,
  int ep = 1,
  int page = 1,
  int? maxPage,
  List<String> readEpisode = const [],
  DateTime? time,
  int? group,
}) {
  final history = History.fromMap({
    'type': typeValue,
    'time': (time ?? DateTime(2026, 1, 1)).millisecondsSinceEpoch,
    'title': 'Title $id',
    'subtitle': 'Subtitle $id',
    'cover': 'https://example.com/$id.jpg',
    'ep': ep,
    'page': page,
    'id': id,
    'readEpisode': readEpisode,
    'max_page': maxPage,
  });
  history.group = group;
  return history;
}

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('HistoryManager', () {
    late HistoryManager manager;

    setUp(() {
      manager = HistoryManager.forTesting();
      addTearDown(manager.close);
    });

    test('starts empty and initialized', () {
      expect(manager.isInitialized, isTrue);
      expect(manager.count(), 0);
      expect(manager.length, 0);
      expect(manager.getAll(), isEmpty);
    });

    test('addHistory + find round-trips all fields', () {
      final item = _stubHistory(
        'c1',
        ep: 3,
        page: 7,
        maxPage: 42,
        readEpisode: ['1', '2', '3'],
        group: 2,
      );
      manager.addHistory(item);

      // Bypass the in-memory object cache to force a database read.
      manager.cachedHistories.clear();
      final found = manager.find('c1', ComicType(0));

      expect(found, isNotNull);
      expect(found!.title, 'Title c1');
      expect(found.subtitle, 'Subtitle c1');
      expect(found.cover, 'https://example.com/c1.jpg');
      expect(found.ep, 3);
      expect(found.page, 7);
      expect(found.maxPage, 42);
      expect(found.readEpisode, {'1', '2', '3'});
      expect(found.group, 2);
      expect(found.time, DateTime(2026, 1, 1));
    });

    test('addHistory with same id and type upserts instead of duplicating',
        () {
      manager.addHistory(_stubHistory('c1', page: 1));
      manager.addHistory(_stubHistory('c1', page: 99));

      expect(manager.count(), 1);
      manager.cachedHistories.clear();
      expect(manager.find('c1', ComicType(0))!.page, 99);
    });

    test('find returns null for unknown id', () {
      manager.addHistory(_stubHistory('c1'));
      expect(manager.find('missing', ComicType(0)), isNull);
    });

    test('getAll and getRecent order by time descending', () {
      manager.addHistory(_stubHistory('old', time: DateTime(2026, 1, 1)));
      manager.addHistory(_stubHistory('new', time: DateTime(2026, 3, 1)));
      manager.addHistory(_stubHistory('mid', time: DateTime(2026, 2, 1)));

      expect(manager.getAll().map((h) => h.id), ['new', 'mid', 'old']);
      expect(manager.getRecent().map((h) => h.id), ['new', 'mid', 'old']);
    });

    test('remove deletes a single record', () {
      manager.addHistory(_stubHistory('c1'));
      manager.addHistory(_stubHistory('c2'));

      manager.remove('c1', ComicType(0));

      expect(manager.count(), 1);
      expect(manager.find('c1', ComicType(0)), isNull);
      expect(manager.find('c2', ComicType(0)), isNotNull);
    });

    test('batchDeleteHistories removes all given records', () {
      manager.addHistory(_stubHistory('c1'));
      manager.addHistory(_stubHistory('c2'));
      manager.addHistory(_stubHistory('c3'));

      manager.batchDeleteHistories([
        ComicID(ComicType(0), 'c1'),
        ComicID(ComicType(0), 'c3'),
      ]);

      expect(manager.getAll().map((h) => h.id), ['c2']);
    });

    test('clearHistory empties the table and caches', () {
      manager.addHistory(_stubHistory('c1'));
      manager.addHistory(_stubHistory('c2'));

      manager.clearHistory();

      expect(manager.count(), 0);
      expect(manager.find('c1', ComicType(0)), isNull);
      expect(manager.cachedHistories, isEmpty);
    });

    test('addHistory notifies listeners', () {
      var notified = 0;
      manager.addListener(() => notified++);

      manager.addHistory(_stubHistory('c1'));

      expect(notified, 1);
    });

    test('debugSetInstance overrides the factory singleton', () {
      final injected = HistoryManager.forTesting();
      addTearDown(() => HistoryManager.debugSetInstance(null));

      HistoryManager.debugSetInstance(injected);

      expect(identical(HistoryManager(), injected), isTrue);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
