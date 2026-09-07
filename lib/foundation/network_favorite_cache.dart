import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app.dart';
import 'log.dart';

/// Per-source cache of comic IDs known to be in the user's network
/// (server-side) favorites.
///
/// Network favorite state lives on the source's server and can only be
/// queried per comic or fetched page by page, so comic tiles cannot ask for
/// it while rendering. This cache is filled incrementally whenever the app
/// legitimately sees network favorite IDs — browsing the network favorites
/// page, opening a comic's details page (authoritative per-comic state),
/// toggling a network favorite, or importing a network folder — and lets
/// [ComicTile] show a favorite badge for network favorites too.
///
/// Limitation: only comics this device has "seen" are covered. Favorites
/// added on another device appear after the next visit to that source's
/// network favorites page.
class NetworkFavoriteCache with ChangeNotifier {
  NetworkFavoriteCache._();

  static NetworkFavoriteCache? _instance;

  factory NetworkFavoriteCache() {
    return _instance ??= NetworkFavoriteCache._();
  }

  /// Test seam: standalone instance. Combine with [debugSetInstance] to
  /// replace the singleton, and use the pure map methods ([toJsonMap] /
  /// [loadFromJsonMap]) plus [init]/[save] against a temp `App.dataPath`.
  @visibleForTesting
  factory NetworkFavoriteCache.forTesting() => NetworkFavoriteCache._();

  @visibleForTesting
  static void debugSetInstance(NetworkFavoriteCache? instance) {
    _instance = instance;
  }

  final Map<String, Set<String>> _ids = {};

  Timer? _saveTimer;

  bool _loaded = false;

  File get _file => File("${App.dataPath}/network_favorites.json");

  /// Loads the persisted cache. Called once at startup (see init.dart).
  Future<void> init() async {
    try {
      var file = _file;
      if (await file.exists()) {
        loadFromJsonMap(jsonDecode(await file.readAsString()));
      }
    } catch (e, s) {
      Log.error("NetworkFavoriteCache", "Failed to load cache: $e\n$s");
    } finally {
      _loaded = true;
    }
  }

  bool contains(String sourceKey, String comicId) =>
      _ids[sourceKey]?.contains(comicId) ?? false;

  /// Records comics seen in a network favorites listing.
  void addIds(String sourceKey, Iterable<String> ids) {
    var set = _ids.putIfAbsent(sourceKey, () => {});
    var changed = false;
    for (var id in ids) {
      changed |= set.add(id);
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void removeId(String sourceKey, String comicId) {
    var removed = _ids[sourceKey]?.remove(comicId) ?? false;
    if (removed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Records an authoritative per-comic favorite state reported by a source
  /// (e.g. `ComicDetails.isFavorite` or the folder query on the details
  /// page). Unknown states must not be passed here — a wrong `false` would
  /// drop a valid entry.
  void record(String sourceKey, String comicId, bool isFavorite) {
    if (isFavorite) {
      addIds(sourceKey, [comicId]);
    } else {
      removeId(sourceKey, comicId);
    }
  }

  void _scheduleSave() {
    // Don't persist before init() has loaded the previous state, or a fresh
    // change would overwrite the on-disk cache with a partial view.
    if (!_loaded) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), save);
  }

  Future<void> save() async {
    try {
      await _file.writeAsString(jsonEncode(toJsonMap()));
    } catch (e, s) {
      Log.error("NetworkFavoriteCache", "Failed to save cache: $e\n$s");
    }
  }

  Map<String, List<String>> toJsonMap() => {
        for (var e in _ids.entries) e.key: e.value.toList(),
      };

  void loadFromJsonMap(Map<String, dynamic> json) {
    _ids.clear();
    for (var e in json.entries) {
      if (e.value is List) {
        _ids[e.key] = Set<String>.from((e.value as List).whereType<String>());
      }
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
