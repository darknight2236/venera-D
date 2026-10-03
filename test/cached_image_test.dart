import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';

void main() {
  group('CachedImageProvider file:// loading', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('cached_image_test');
      CachedImageProvider.loadingCount = 0;
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
      CachedImageProvider.loadingCount = 0;
    });

    test('keeps the concurrency slot while the read is in flight', () async {
      final file = File('${tempDir.path}/cover.png');
      file.writeAsBytesSync(List.filled(64 * 1024, 0));
      // A broadcast controller, because `load` only adds events on the network
      // path; closing an unlistened single-subscription controller never completes.
      final chunkEvents = StreamController<ImageChunkEvent>.broadcast();

      // An async function body runs synchronously up to its first await, so the
      // counter is observed here while the read is still pending. Returning the
      // read future without `await` ran the `finally` at the return statement,
      // freeing the slot early and letting more than _kMaxLoadingCount reads run.
      final future = CachedImageProvider('file://${file.path}')
          .load(chunkEvents, () {});
      expect(CachedImageProvider.loadingCount, 1);

      expect(await future, hasLength(64 * 1024));
      expect(CachedImageProvider.loadingCount, 0);
      await chunkEvents.close();
    });

    test('releases the slot when the read fails', () async {
      final chunkEvents = StreamController<ImageChunkEvent>.broadcast();

      await expectLater(
        CachedImageProvider('file://${tempDir.path}/missing.png')
            .load(chunkEvents, () {}),
        throwsA(isA<FileSystemException>()),
      );
      expect(CachedImageProvider.loadingCount, 0);
      await chunkEvents.close();
    });
  });
}
