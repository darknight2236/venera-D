import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
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

  group('CacheManager sqlite ownership', () {
    late Directory tempDir;
    late Directory scanDir;
    late Database db;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_scan_test');
      // The database lives outside the scanned tree: a file there would count
      // as unmanaged and the scan would try to delete it.
      db = sqlite3.open('${tempDir.path}/cache.db');
      db.execute('''
        CREATE TABLE cache (
          key TEXT PRIMARY KEY NOT NULL,
          dir TEXT NOT NULL,
          name TEXT NOT NULL,
          expires INTEGER NOT NULL,
          type TEXT
        )
      ''');
      db.execute(
        'INSERT INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)',
        ['k1', '7', 'a.png', DateTime.now().millisecondsSinceEpoch + 60000],
      );
      scanDir = Directory('${tempDir.path}/files')..createSync(recursive: true);
      Directory('${scanDir.path}/7').createSync(recursive: true);
      File('${scanDir.path}/7/a.png').writeAsBytesSync([1, 2, 3]);
      addTearDown(() {
        db.close();
        tempDir.deleteSync(recursive: true);
      });
    });

    test('the scan must not close the connection it reaches through a pointer',
        () async {
      // _scanDir wraps the parent connection with sqlite3.fromPointer() inside
      // Isolate.run. A non-borrowed wrapper owns the handle and the package
      // attaches a native finalizer calling sqlite3_close_v2, so isolate
      // teardown would close the connection the main isolate is still using.
      for (var i = 0; i < 60; i++) {
        final total = await CacheManager.scanDirForTesting(db.handle, scanDir.path);
        expect(total, 3, reason: 'scan #$i should still see the managed file');
      }

      expect(
        () => db.select(
          'SELECT * FROM cache WHERE expires < ?',
          [DateTime.now().millisecondsSinceEpoch],
        ),
        returnsNormally,
        reason: 'the parent connection must survive the borrowed-handle scan',
      );
    });

    test('a failed checkCache does not disable eviction for the session',
        () async {
      App.cachePath = tempDir.path;
      App.dataPath = tempDir.path;
      final manager = CacheManager.forTesting();

      // Closing the database makes the next prepared statement fail. Note the
      // exception type differs by path: an explicit close() trips sqlite3's
      // Dart-side guard (StateError), while the production bug - a foreign
      // finalizer calling sqlite3_close_v2 on a still-used handle - surfaces as
      // SqliteException(21). Either way, the second call must still try.
      manager.close();
      await expectLater(
        manager.checkCache(),
        throwsA(anything),
        reason: 'first attempt should hit the dead connection',
      );
      await expectLater(
        manager.checkCache(),
        throwsA(anything),
        reason: '_isChecking must reset, or eviction never runs again',
      );
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
