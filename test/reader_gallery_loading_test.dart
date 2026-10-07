import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

/// Hands out an already-decoded frame after [delay], so nothing in these tests
/// needs real IO or the codec: the point is the stream bookkeeping inside
/// photo_view, and [delay] decides whether a page is still loading when the
/// next frame is built.
class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  _TestImageProvider(this.frame, {this.delay = Duration.zero});

  final ui.Image frame;
  final Duration delay;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_TestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) {
    ImageInfo info() => ImageInfo(image: frame);
    return OneFrameImageStreamCompleter(delay == Duration.zero
        // A microtask, which pump() flushes; Future.delayed would arm a Timer
        // that no zero-duration pump advances.
        ? Future<ImageInfo>.value(info())
        : Future<ImageInfo>.delayed(delay, info));
  }
}

/// Toggling the reader's toolbars also flips the system UI mode, which changes
/// the window insets - and with them `MediaQuery` for everything that depends on
/// it. The vendored photo_view wrapper used to answer such a change by setting
/// its `_loading` flag again even though the image stream it already holds is
/// unchanged; because no new frame arrives to clear the flag, the page dropped
/// back to its spinner although the image was right there. Local comics showed
/// it too: no network was involved either way.
void main() {
  late ui.Image frame;

  setUp(() async {
    // Requires real async, so it cannot happen inside the test body. Uncached:
    // each test releases its own image.
    frame = await createTestImage(width: 2, height: 2, cache: false);
  });

  /// The reader's own loading builder reads MediaQuery, which is what makes the
  /// wrapper depend on the insets in the first place - keep that shape here.
  Widget gallery(ImageProvider provider) {
    return PhotoView(
      imageProvider: provider,
      loadingBuilder: (context, event) => SizedBox(
        width: MediaQuery.of(context).size.width,
        child: const CircularProgressIndicator(),
      ),
    );
  }

  Widget app(double topPadding, Widget child) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(top: topPadding)),
        child: child,
      ),
    );
  }

  testWidgets('a padding change must not send a loaded page back to its spinner',
      (tester) async {
    final provider = _TestImageProvider(frame);

    await tester.pumpWidget(app(0, gallery(provider)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the page should be on screen before the toolbar is touched');

    // What SystemChrome.setEnabledSystemUIMode does to the layout: only the
    // window insets change, the image does not.
    await tester.pumpWidget(app(24, gallery(provider)));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'hiding or showing the toolbars must not restart the page');
  });

  testWidgets('a page that is still arriving shows the loading state',
      (tester) async {
    await tester.pumpWidget(app(0, gallery(_TestImageProvider(frame))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // A different image is a different stream, so the page has to fall back to
    // the spinner until that stream delivers its frame: the behaviour the
    // loading flag exists for, and which the fix must keep.
    await tester.pumpWidget(app(
      0,
      gallery(_TestImageProvider(frame, delay: const Duration(milliseconds: 50))),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the new page arrives as soon as its stream delivers a frame');
  });
}
