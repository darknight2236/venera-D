import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/data_sync.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

Future<ComicUpdateResult> updateComic(
    FavoriteItemWithUpdateInfo c, String folder) async {
  int retries = 3;
  while (true) {
    try {
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return ComicUpdateResult(false, "Comic source not found");
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author: newInfo.subTitle ??
            newInfo.tags['author']?.firstOrNull ??
            c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updated = false;
      var updateTime = newInfo.findUpdateTime();
      if (updateTime != null && updateTime != c.updateTime) {
        LocalFavoritesManager().updateUpdateTime(
          folder,
          c.id,
          c.type,
          updateTime,
        );
        updated = true;
      } else {
        LocalFavoritesManager().updateCheckTime(folder, c.id, c.type);
      }
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      Log.error("Check Updates", e, s);
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        return ComicUpdateResult(false, e.toString());
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(this.total, this.current, this.errors, this.updated,
      [this.comic, this.errorMessage]);
}

void updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime,
) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  int total = comics.length;
  int current = 0;
  int errors = 0;
  int updated = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];

  for (var comic in comics) {
    if (!ignoreCheckTime) {
      var lastCheckTime = comic.lastCheckTime;
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    comicsToUpdate.add(comic);
  }

  total = comicsToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);

  // Producer
  () async {
    var c = 0;
    for (var comic in comicsToUpdate) {
      await channel.push(comic);
      c++;
      // Throttle
      if (c % 5 == 0) {
        var delay = c % 100 + 1;
        if (delay > 10) {
          delay = 10;
        }
        await Future.delayed(Duration(seconds: delay));
      }
    }
    channel.close();
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < 5; i++) {
    var f = () async {
      while (true) {
        var comic = await channel.pop();
        if (comic == null) {
          break;
        }
        var result = await updateComic(comic, folder);
        current++;
        if (result.updated) {
          updated++;
        }
        if (result.errorMessage != null) {
          errors++;
        }
        stream.add(UpdateProgress(total, current, errors, updated, comic, result.errorMessage));
      }
    }();
    updateFutures.add(f);
  }

  await Future.wait(updateFutures);

  if (updated > 0) {
    LocalFavoritesManager().notifyChanges();
  }

  stream.close();
}


Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) {
  var stream = StreamController<UpdateProgress>();
  updateFolderBase(folder, stream, ignoreCheckTime);
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedComics.map((c) => {
    'id': c.id,
    'name': c.name,
    'coverUrl': c.coverPath,
    'author': c.author,
    'type': c.type.sourceKey,
    'updateTime': c.updateTime,
    'tags': c.tags,
  }).toList();
  return jsonEncode(jsonList);
}

/// Background service for checking follow updates.
abstract class FollowUpdatesService {
  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  /// Cancel the ongoing background check, if any.
  static void cancelChecking() {
    _cancelChecking?.call();
  }

  static void _check() async {
    if (_isChecking) {
      return;
    }
    var folder = appdata.settings["followUpdatesFolder"];
    if (folder == null) {
      return;
    }
    bool isCanceled = false;
    _cancelChecking = () {
      isCanceled = true;
    };

    _isChecking = true;

    while (DataSync().isDownloading) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    int updated = 0;
    try {
      await for (var progress in updateFolder(folder, false)) {
        if (isCanceled) {
          return;
        }
        updated = progress.updated;
      }
    } finally {
      _cancelChecking = null;
      _isChecking = false;
      if (updated > 0) {
        LocalFavoritesManager.onFollowUpdatesChanged?.call();
      }
    }
  }

  /// Initialize the checker.
  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    _check();
    DataSync()
        .addListener(() => LocalFavoritesManager.onFollowUpdatesChanged?.call());
    // A short interval will not affect the performance since every comic has a check time.
    Timer.periodic(const Duration(minutes: 10), (timer) {
      _check();
    });
  }
}
