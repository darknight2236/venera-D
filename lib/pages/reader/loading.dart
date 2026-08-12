part of 'reader.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: widget.initialEp ?? data.history.ep,
      initialPage: widget.initialPage ?? data.history.page,
      initialChapterGroup: data.history.group,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    var comicSource = ComicSource.find(widget.sourceKey);
    var history = HistoryManager().find(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    if (comicSource == null) {
      var localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history: history ??
              History.fromModel(
                model: localComic,
                ep: 0,
                page: 0,
              ),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    } else {
      var comic = await comicSource.loadComicInfo!(widget.id);
      if (comic.error) {
        return Res.fromErrorRes(comic);
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: comic.data.title,
          chapters: comic.data.chapters,
          history: history ??
              History.fromModel(
                model: comic.data,
                ep: 0,
                page: 0,
              ),
          author: comic.data.findAuthor() ?? "",
          tags: comic.data.plainTags,
        ),
      );
    }
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}

/// Opens the reader for [id]/[sourceKey], letting the user choose between
/// starting over and continuing from the last position when reading progress
/// exists (upstream #795).
void openReaderWithProgressChoice(
  BuildContext context,
  String id,
  String sourceKey,
) {
  var history = HistoryManager().find(id, ComicType.fromKey(sourceKey));
  void open({int? initialEp, int? initialPage}) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ReaderWithLoading(
        id: id,
        sourceKey: sourceKey,
        initialEp: initialEp,
        initialPage: initialPage,
      ),
    );
  }

  if (history != null && history.page > 0) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("Resume reading?".tl),
        content: Text("This comic has reading progress.".tl),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              open(initialEp: 1, initialPage: 1);
            },
            child: Text("From the beginning".tl),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              open();
            },
            child: Text("Continue".tl),
          ),
        ],
      ),
    );
  } else {
    open();
  }
}
