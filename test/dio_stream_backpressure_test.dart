import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// Backpressure contract for the three `ResponseType.stream` call sites
// (network/file_downloader.dart `_fetchBlock`, network/images.dart twice), all
// of which `await for` over `ResponseBody.stream` and await a file write inside
// the loop body. dio pipes the adapter stream through its own controller, so
// the consumer pausing must also pause dio's subscription to the adapter —
// otherwise the rest of the response is buffered in memory.

const chunkCount = 20;
const chunkSize = 1024;

/// Acts like a socket: it only advances when its subscriber is ready, so
/// [produced] measures how much of the response was pulled out of the adapter.
class TrackedSource {
  int produced = 0;

  Stream<Uint8List> stream() async* {
    for (var i = 0; i < chunkCount; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      produced++;
      yield Uint8List(chunkSize);
    }
  }
}

class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.source);

  final Stream<Uint8List> source;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody(source, 200);

  @override
  void close({bool force = false}) {}
}

/// Starts a streamed download whose consumer holds inside the loop body until
/// [hold] completes, the way `_fetchBlock` does while writing to disk.
StreamedDownload startDownload(TrackedSource source) {
  final dio = Dio()..httpClientAdapter = StubAdapter(source.stream());
  final delivered = <int>[];
  final hold = Completer<void>();
  final enteredBody = Completer<void>();
  final finished = () async {
    final response = await dio.get<ResponseBody>(
      'https://example.com/comic.cbz',
      options: Options(responseType: ResponseType.stream),
    );
    await for (final chunk in response.data!.stream) {
      delivered.add(chunk.length);
      if (delivered.length == 1) {
        enteredBody.complete();
        await hold.future;
      }
    }
    dio.close(force: true);
  }();
  return StreamedDownload(
    delivered: delivered,
    hold: hold,
    enteredBody: enteredBody,
    finished: finished,
  );
}

class StreamedDownload {
  StreamedDownload({
    required this.delivered,
    required this.hold,
    required this.enteredBody,
    required this.finished,
  });

  final List<int> delivered;
  final Completer<void> hold;
  final Completer<void> enteredBody;
  final Future<void> finished;
}

void main() {
  test('a writer that awaits inside the loop stops the source being pulled',
      () async {
    final source = TrackedSource();
    final download = startDownload(source);

    await download.enteredBody.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final pulledWhileHeld = source.produced;
    download.hold.complete();
    await download.finished;

    expect(
      pulledWhileHeld,
      lessThanOrEqualTo(5),
      reason: 'dio must pause its subscription to the adapter stream while the '
          'consumer awaits. $pulledWhileHeld of $chunkCount chunks were pulled '
          'during the hold, so the remaining response was buffered in memory.',
    );
  });

  test('releasing the paused writer delivers the rest of the stream', () async {
    final source = TrackedSource();
    final download = startDownload(source);

    await download.enteredBody.future;
    download.hold.complete();
    await download.finished;

    expect(download.delivered, List.generate(chunkCount, (_) => chunkSize));
    expect(download.delivered.length, chunkCount);
  });

  test('the whole response is delivered when the writer never pauses',
      () async {
    final source = TrackedSource();
    final dio = Dio()..httpClientAdapter = StubAdapter(source.stream());

    final response = await dio.get<ResponseBody>(
      'https://example.com/comic.cbz',
      options: Options(responseType: ResponseType.stream),
    );
    var total = 0;
    await for (final chunk in response.data!.stream) {
      total += chunk.length;
    }
    dio.close(force: true);

    expect(total, chunkCount * chunkSize);
  });
}
