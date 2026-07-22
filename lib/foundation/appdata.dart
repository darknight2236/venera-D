import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

class Appdata with Init {
  Appdata._create();

  /// Creates an instance without any I/O, for unit tests.
  ///
  /// The production [appdata] global runs [doInit]/[saveData] against the
  /// filesystem; this constructor skips all of that so tests can exercise
  /// pure logic such as [toJson]/[loadFromJson].
  @visibleForTesting
  Appdata.forTesting();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  bool _isSavingData = false;

  Future<void> saveData([bool sync = true]) async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var futures = <Future>[];
      var json = toJson();
      var data = jsonEncode(json);
      var file = File(FilePath.join(App.dataPath, 'appdata.json'));
      futures.add(file.writeAsString(data));

      var disableSyncFields = json["settings"]["disableSyncFields"] as String;
      if (disableSyncFields.isNotEmpty) {
        var json4sync = jsonDecode(data);
        List<String> customDisableSync = splitField(disableSyncFields);
        for (var field in customDisableSync) {
          json4sync["settings"].remove(field);
        }
        var data4sync = jsonEncode(json4sync);
        var file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
        futures.add(file4sync.writeAsString(data4sync));
      }

      await Future.wait(futures);
    } finally {
      _isSavingData = false;
    }
    if (sync) {
      DataSync().uploadData();
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  /// Populates [settings] and [searchHistory] from a decoded json [map].
  ///
  /// Pure (no I/O); extracted from [doInit] so the deserialization logic can
  /// be unit-tested. Mirrors the previous inline behavior, including skipping
  /// null setting values.
  void loadFromJson(Map<String, dynamic> map) {
    for (var key in (map['settings'] as Map<String, dynamic>).keys) {
      if (map['settings'][key] != null) {
        settings[key] = map['settings'][key];
      }
    }
    searchHistory = List.from(map['searchHistory']);
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
  ];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data) {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings[SettingKeys.disableSyncFields] as String,
      );

      for (var key in settings.keys) {
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }
    }
    searchHistory = List.from(data['searchHistory'] ?? []);
    saveData();
  }

  var implicitData = <String, dynamic>{};

  void writeImplicitData() async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
      await file.writeAsString(jsonEncode(implicitData));
    } finally {
      _isSavingData = false;
    }
  }

  @override
  Future<void> doInit() async {
    var dataPath = (await getApplicationSupportDirectory()).path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    try {
      var json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      loadFromJson(json);
    } catch (e) {
      Log.error("Appdata", "Failed to load appdata", e);
      Log.info("Appdata", "Resetting appdata");
      file.deleteIgnoreError();
    }
    if ((settings[SettingKeys.deviceId] as String).isEmpty) {
      settings._data[SettingKeys.deviceId] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = jsonDecode(await implicitDataFile.readAsString());
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
  }
}

Appdata? _appdata;

Appdata get appdata => _appdata ??= Appdata._create();

/// Allows tests to replace the global [appdata] instance.
@visibleForTesting
set appdata(Appdata value) => _appdata = value;

/// Central registry of [Settings] keys.
///
/// Use these constants instead of bare string literals when reading or writing
/// settings (including the reader-setting helpers, which take a `String` key),
/// so a mistyped key becomes a compile-time error rather than a silent `null`.
/// Constant names mirror the stored key strings; the two snake_case keys are
/// exposed under camelCase names.
abstract final class SettingKeys {
  static const comicDisplayMode = 'comicDisplayMode';
  static const comicTileScale = 'comicTileScale';
  static const color = 'color';
  static const themeMode = 'theme_mode';
  static const newFavoriteAddTo = 'newFavoriteAddTo';
  static const moveFavoriteAfterRead = 'moveFavoriteAfterRead';
  static const proxy = 'proxy';
  static const explorePages = 'explore_pages';
  static const categories = 'categories';
  static const favorites = 'favorites';
  static const searchSources = 'searchSources';
  static const showFavoriteStatusOnTile = 'showFavoriteStatusOnTile';
  static const showHistoryStatusOnTile = 'showHistoryStatusOnTile';
  static const blockedWords = 'blockedWords';
  static const blockedCommentWords = 'blockedCommentWords';
  static const defaultSearchTarget = 'defaultSearchTarget';
  static const autoPageTurningInterval = 'autoPageTurningInterval';
  static const readerMode = 'readerMode';
  static const readerScreenPicNumberForLandscape =
      'readerScreenPicNumberForLandscape';
  static const readerScreenPicNumberForPortrait =
      'readerScreenPicNumberForPortrait';
  static const enableTapToTurnPages = 'enableTapToTurnPages';
  static const reverseTapToTurnPages = 'reverseTapToTurnPages';
  static const enablePageAnimation = 'enablePageAnimation';
  static const language = 'language';
  static const cacheSize = 'cacheSize';
  static const downloadThreads = 'downloadThreads';
  static const enableLongPressToZoom = 'enableLongPressToZoom';
  static const longPressZoomPosition = 'longPressZoomPosition';
  static const checkUpdateOnStart = 'checkUpdateOnStart';
  static const limitImageWidth = 'limitImageWidth';
  static const webdav = 'webdav';
  static const disableSyncFields = 'disableSyncFields';
  static const dataVersion = 'dataVersion';
  static const quickFavorite = 'quickFavorite';
  static const enableTurnPageByVolumeKey = 'enableTurnPageByVolumeKey';
  static const enableClockAndBatteryInfoInReader =
      'enableClockAndBatteryInfoInReader';
  static const quickCollectImage = 'quickCollectImage';
  static const authorizationRequired = 'authorizationRequired';
  static const onClickFavorite = 'onClickFavorite';
  static const enableDnsOverrides = 'enableDnsOverrides';
  static const dnsOverrides = 'dnsOverrides';
  static const enableCustomImageProcessing = 'enableCustomImageProcessing';
  static const customImageProcessing = 'customImageProcessing';
  static const sni = 'sni';
  static const autoAddLanguageFilter = 'autoAddLanguageFilter';
  static const comicSourceListUrl = 'comicSourceListUrl';
  static const preloadImageCount = 'preloadImageCount';
  static const followUpdatesFolder = 'followUpdatesFolder';
  static const initialPage = 'initialPage';
  static const comicListDisplayMode = 'comicListDisplayMode';
  static const showPageNumberInReader = 'showPageNumberInReader';
  static const showSingleImageOnFirstPage = 'showSingleImageOnFirstPage';
  static const enableDoubleTapToZoom = 'enableDoubleTapToZoom';
  static const reverseChapterOrder = 'reverseChapterOrder';
  static const showSystemStatusBar = 'showSystemStatusBar';
  static const comicSpecificSettings = 'comicSpecificSettings';
  static const deviceSpecificSettings = 'deviceSpecificSettings';
  static const deviceId = 'deviceId';
  static const ignoreBadCertificate = 'ignoreBadCertificate';
  static const readerScrollSpeed = 'readerScrollSpeed';
  static const localFavoritesFirst = 'localFavoritesFirst';
  static const autoCloseFavoritePanel = 'autoCloseFavoritePanel';
  static const showChapterComments = 'showChapterComments';
  static const showChapterCommentsAtEnd = 'showChapterCommentsAtEnd';
}

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': _defaultSourceListUrl,
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

const _defaultSourceListUrl =
    "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
