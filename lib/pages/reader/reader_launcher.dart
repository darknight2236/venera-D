import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';

import 'reader.dart';

/// UI-layer implementation that opens the reader page from [ReaderLaunchData].
///
/// Registered on [LocalComic.readerLauncher] at app startup (see
/// main_page.dart) so that foundation/local.dart does not need to import the
/// reader page.
void launchReader(ReaderLaunchData data) {
  App.rootContext.to(
    () => Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      initialChapter: data.initialChapter,
      initialPage: data.initialPage,
      initialChapterGroup: data.initialChapterGroup,
      history: data.history,
      author: data.author,
      tags: data.tags,
    ),
  );
}
