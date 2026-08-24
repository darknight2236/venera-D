import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/source_timeout.dart';

void main() {
  group('runWithSourceTimeout', () {
    test('returns the task result when it completes in time', () async {
      final result = await runWithSourceTimeout(
        () async => 42,
        timeout: const Duration(seconds: 5),
      );
      expect(result, 42);
    });

    test('throws TimeoutException when the task never completes', () async {
      // Simulates a hung JS source request (upstream issue #825): the future
      // never completes, and the timeout must surface as a TimeoutException
      // so the caller can turn it into a retriable error state.
      await expectLater(
        runWithSourceTimeout(
          () => Completer<int>().future,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('propagates task errors unchanged', () async {
      await expectLater(
        runWithSourceTimeout<int>(
          () async => throw StateError('source exploded'),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('default timeout matches the download pipeline bound', () {
      expect(kSourceRequestTimeout, const Duration(seconds: 30));
    });
  });
}
