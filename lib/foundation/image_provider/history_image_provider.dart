import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import '../source_request.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  /// Records recent cover-refresh attempts per comic, so a dead cover that
  /// the source cannot replace does not trigger `loadComicInfo` on every
  /// list rebuild (upstream issue #742).
  static final Map<String, DateTime> _recentRefreshAttempts = {};

  static const _refreshAttemptTtl = Duration(minutes: 5);

  static const _maxRefreshAttemptEntries = 256;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      var comicSource =
          history.type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      HistoryManager().addHistory(history);
    }
    try {
      return await _loadUrl(url, chunkEvents, checkStop);
    } catch (e) {
      // Re-throws if the load was cancelled while we were failing.
      checkStop();
      // Same local-cover fallback favorites enjoy: if the comic has been
      // downloaded, its local cover is authoritative anyway.
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        var file = localComic.coverFile;
        if (await file.exists()) {
          var data = await file.readAsBytes();
          if (data.isNotEmpty) {
            return data;
          }
        }
      }
      // The stored cover may be dead (deleted on the source site, or the
      // history snapshot predates a cover change). Re-fetch once from the
      // source and retry when the URL actually changed (#742).
      var refreshed = await _tryRefreshCoverUrl();
      if (refreshed != null && refreshed != url) {
        checkStop();
        return await _loadUrl(refreshed, chunkEvents, checkStop);
      }
      rethrow;
    }
  }

  Future<Uint8List> _loadUrl(
      String url, chunkEvents, void Function() checkStop) async {
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(ImageChunkEvent(
        cumulativeBytesLoaded: progress.currentBytes,
        expectedTotalBytes: progress.totalBytes,
      ));
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  /// Asks the comic source for the latest cover. Returns the new URL and
  /// persists it on the history entry, or `null` when no usable update
  /// exists. Throttled per comic so a permanently dead cover costs at most
  /// one source call per [_refreshAttemptTtl].
  Future<String?> _tryRefreshCoverUrl() async {
    var comicSource = history.type.comicSource;
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return null;
    }
    var attemptKey = "${history.type.value}@${history.id}";
    var now = DateTime.now();
    var lastAttempt = _recentRefreshAttempts[attemptKey];
    if (lastAttempt != null && now.difference(lastAttempt) < _refreshAttemptTtl) {
      return null;
    }
    _recentRefreshAttempts[attemptKey] = now;
    if (_recentRefreshAttempts.length > _maxRefreshAttemptEntries) {
      _recentRefreshAttempts
          .removeWhere((_, time) => now.difference(time) >= _refreshAttemptTtl);
    }
    try {
      // Bounded by a timeout like every other source request: a hung JS
      // source must not freeze cover loading forever (#825/#742).
      var res = await runWithSourceTimeout(
        () => comicSource.loadComicInfo!(history.id),
      );
      if (res.error) {
        return null;
      }
      var newCover = res.data.cover;
      if (newCover.isEmpty || newCover == history.cover) {
        return null;
      }
      history.cover = newCover;
      HistoryManager().addHistory(history);
      return newCover;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
