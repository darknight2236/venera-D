import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/network/images.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('ImageDownloader cache-first loading', () {
    late CacheManager manager;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_img_test');
      App.cachePath = tempDir.path;
      App.dataPath = tempDir.path;
      manager = CacheManager.forTesting();
      CacheManager.debugSetInstance(manager);
      addTearDown(() {
        CacheManager.debugSetInstance(null);
        manager.close();
        tempDir.deleteSync(recursive: true);
      });
    });

    test('valid cache emits exactly once and never reaches the network',
        () async {
      final bytes = utf8.encode('fake-image-bytes');
      final key = 'img@null@cid@eid';
      await CacheManager().writeCache(key, bytes);

      final events =
          await ImageDownloader.loadComicImageUnwrapped('img', null, 'cid', 'eid')
              .toList();

      final withBytes = events.where((e) => e.imageBytes != null).toList();
      expect(withBytes, hasLength(1));
      expect(withBytes.single.imageBytes, bytes);
    });

    test('empty cache record is dropped so it can be repopulated', () async {
      final key = 'empty@null@cid@eid';
      await CacheManager().writeCache(key, const []);

      // The stale record must be cleaned up by the loader before the network
      // fallback (which would throw for this fake key).
      await expectLater(
        () => ImageDownloader.loadComicImageUnwrapped('empty', null, 'cid', 'eid')
            .toList(),
        throwsA(anything),
      );

      expect(await CacheManager().findCache(key), isNull);
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}