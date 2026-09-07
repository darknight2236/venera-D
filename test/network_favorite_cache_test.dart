import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/network_favorite_cache.dart';

void main() {
  group('NetworkFavoriteCache in-memory operations', () {
    late NetworkFavoriteCache cache;

    setUp(() {
      cache = NetworkFavoriteCache.forTesting();
    });

    tearDown(() {
      cache.dispose();
    });

    test('contains is false for unknown source/comic', () {
      expect(cache.contains('src', 'id'), isFalse);
    });

    test('addIds records comics and contains finds them', () {
      cache.addIds('src', ['a', 'b']);
      expect(cache.contains('src', 'a'), isTrue);
      expect(cache.contains('src', 'b'), isTrue);
      expect(cache.contains('src', 'c'), isFalse);
      expect(cache.contains('other', 'a'), isFalse);
    });

    test('removeId drops a single entry', () {
      cache.addIds('src', ['a', 'b']);
      cache.removeId('src', 'a');
      expect(cache.contains('src', 'a'), isFalse);
      expect(cache.contains('src', 'b'), isTrue);
    });

    test('record adds on true and removes on false', () {
      cache.record('src', 'a', true);
      expect(cache.contains('src', 'a'), isTrue);
      cache.record('src', 'a', false);
      expect(cache.contains('src', 'a'), isFalse);
    });

    test('notifies only when the id set actually changes', () {
      var notifications = 0;
      cache.addListener(() => notifications++);
      cache.addIds('src', ['a']);
      expect(notifications, 1);
      cache.addIds('src', ['a']); // duplicate, no change
      expect(notifications, 1);
      cache.addIds('src', ['b']);
      expect(notifications, 2);
      cache.removeId('src', 'missing');
      expect(notifications, 2);
      cache.removeId('src', 'b');
      expect(notifications, 3);
    });

    test('json round-trip preserves per-source ids', () {
      cache.addIds('src1', ['a', 'b']);
      cache.addIds('src2', ['c']);
      final restored = NetworkFavoriteCache.forTesting();
      restored.loadFromJsonMap(cache.toJsonMap());
      expect(restored.contains('src1', 'a'), isTrue);
      expect(restored.contains('src1', 'b'), isTrue);
      expect(restored.contains('src2', 'c'), isTrue);
      expect(restored.contains('src1', 'c'), isFalse);
      restored.dispose();
    });
  });

  group('NetworkFavoriteCache persistence', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_netfav_test');
      App.dataPath = tempDir.path;
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('init loads what save wrote', () async {
      final cache = NetworkFavoriteCache.forTesting();
      await cache.init(); // no file yet
      cache.addIds('src', ['a']);
      await cache.save();
      cache.dispose(); // cancels the debounced save timer

      final restored = NetworkFavoriteCache.forTesting();
      await restored.init();
      expect(restored.contains('src', 'a'), isTrue);
      restored.dispose();
    });

    test('init on a missing file leaves the cache empty', () async {
      final cache = NetworkFavoriteCache.forTesting();
      await cache.init();
      expect(cache.contains('src', 'a'), isFalse);
      cache.dispose();
    });
  });
}
