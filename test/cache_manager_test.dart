import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('CacheManager', () {
    late CacheManager manager;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_cache_test');
      App.cachePath = tempDir.path;
      App.dataPath = tempDir.path;
      manager = CacheManager.forTesting();
      addTearDown(() {
        manager.close();
        tempDir.deleteSync(recursive: true);
      });
    });

    test('writeCache + findCache round-trips file content', () async {
      await manager.writeCache('key1', utf8.encode('hello venera'));

      final file = await manager.findCache('key1');

      expect(file, isNotNull);
      expect(await file!.readAsString(), 'hello venera');
      expect(manager.currentSize, utf8.encode('hello venera').length);
    });

    test('findCache returns null for unknown key', () async {
      expect(await manager.findCache('missing'), isNull);
    });

    test('expired cache is deleted on lookup', () async {
      await manager.writeCache('key1', [1, 2, 3], -1000);

      final file = await manager.findCache('key1');

      expect(file, isNull);
      // A second lookup also misses (row removed).
      expect(await manager.findCache('key1'), isNull);
    });

    test('delete removes entry, file and size accounting', () async {
      await manager.writeCache('key1', [1, 2, 3, 4]);
      expect(manager.currentSize, 4);

      await manager.delete('key1');

      expect(await manager.findCache('key1'), isNull);
      expect(manager.currentSize, 0);
    });

    test('overwriting a key replaces the previous entry', () async {
      await manager.writeCache('key1', [1, 2, 3, 4]);
      await manager.writeCache('key1', [9, 9]);

      final file = await manager.findCache('key1');

      expect(await file!.readAsBytes(), [9, 9]);
      expect(manager.currentSize, 2);
    });

    test('checkCache evicts entries beyond the size limit', () async {
      await manager.writeCache('key1', List.filled(100, 1));
      await manager.writeCache('key2', List.filled(100, 2));
      manager.setLimitSize(0);

      await manager.checkCache();

      expect(manager.currentSize, 0);
      expect(await manager.findCache('key1'), isNull);
      expect(await manager.findCache('key2'), isNull);
    });

    test('clear wipes all entries and resets size', () async {
      await manager.writeCache('key1', [1]);
      await manager.writeCache('key2', [2]);

      await manager.clear();

      expect(manager.currentSize, 0);
      expect(await manager.findCache('key1'), isNull);
      expect(await manager.findCache('key2'), isNull);
    });

    test('debugSetInstance overrides the factory singleton', () {
      final injected = CacheManager.forTesting();
      addTearDown(() => CacheManager.debugSetInstance(null));

      CacheManager.debugSetInstance(injected);

      expect(identical(CacheManager(), injected), isTrue);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
