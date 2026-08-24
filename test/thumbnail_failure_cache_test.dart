import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/source_request.dart';
import 'package:venera/network/images.dart';

void main() {
  group('ThumbnailFailureCache', () {
    test('unmarked keys are not failed', () {
      final cache = ThumbnailFailureCache();
      expect(cache.isFailed('url@key'), isFalse);
    });

    test('marked keys are failed within the TTL', () {
      final cache =
          ThumbnailFailureCache(duration: const Duration(minutes: 5));
      final now = DateTime(2026);
      cache.markFailed('url@key', now);
      expect(cache.isFailed('url@key', now.add(const Duration(minutes: 4))),
          isTrue);
    });

    test('entries expire after the TTL', () {
      final cache =
          ThumbnailFailureCache(duration: const Duration(minutes: 5));
      final now = DateTime(2026);
      cache.markFailed('url@key', now);
      expect(cache.isFailed('url@key', now.add(const Duration(minutes: 6))),
          isFalse);
      // The expired entry was removed on access.
      expect(cache.isFailed('url@key', now), isFalse);
    });

    test('clear removes a single entry', () {
      final cache = ThumbnailFailureCache();
      cache.markFailed('a');
      cache.markFailed('b');
      cache.clear('a');
      expect(cache.isFailed('a'), isFalse);
      expect(cache.isFailed('b'), isTrue);
    });

    test('clearAll drops every entry', () {
      final cache = ThumbnailFailureCache();
      cache.markFailed('a');
      cache.markFailed('b');
      cache.clearAll();
      expect(cache.isFailed('a'), isFalse);
      expect(cache.isFailed('b'), isFalse);
    });

    test('overflow pruning drops expired entries and keeps live ones', () {
      final cache =
          ThumbnailFailureCache(duration: const Duration(minutes: 5));
      final now = DateTime(2026);
      // One already-expired entry plus enough live ones to overflow the
      // internal limit, which triggers pruning.
      cache.markFailed('expired', now.subtract(const Duration(minutes: 10)));
      for (var i = 0; i < 260; i++) {
        cache.markFailed('key$i', now);
      }
      expect(cache.isFailed('expired', now), isFalse);
      expect(cache.isFailed('key0', now), isTrue);
      expect(cache.isFailed('key259', now), isTrue);
    });
  });

  group('runWithSourceTimeout (foundation)', () {
    test('returns the task result when it completes in time', () async {
      final result = await runWithSourceTimeout(
        () async => 'ok',
        timeout: const Duration(seconds: 5),
      );
      expect(result, 'ok');
    });

    test('throws TimeoutException when the source request never completes',
        () async {
      // A hung JS source (upstream issues #825/#742) must surface as a
      // TimeoutException instead of blocking the caller forever.
      await expectLater(
        runWithSourceTimeout(
          () => Completer<int>().future,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('default timeout matches the download pipeline bound', () {
      expect(kSourceRequestTimeout, const Duration(seconds: 30));
    });
  });
}
