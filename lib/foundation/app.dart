import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/history.dart';

import 'appdata.dart';
import 'favorites.dart';
import 'local.dart';

export "widget_utils.dart";
export "context.dart";

class _App {
  final version = "1.6.3";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings[SettingKeys.language] != 'system') {
      return Locale(
        appdata.settings[SettingKeys.language].split('-')[0],
        appdata.settings[SettingKeys.language].split('-')[1],
      );
    }
    return deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final LocalFavoritesManager favorites = LocalFavoritesManager();

  final LocalManager local = LocalManager();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  Future<void> initComponents() async {
    await Future.wait([
      data.init(),
      history.init(),
      favorites.init(),
      local.init(),
    ]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }

  /// Shows the app-update dialog. Registered by the UI layer (MyApp)
  /// so that init.dart does not depend on pages/.
  Future<void> Function(bool showMessageIfNoUpdate, bool delay)?
      appUpdateUiHandler;
}

_App? _app;

// ignore: non_constant_identifier_names, library_private_types_in_public_api
_App get App => _app ??= _App();

/// Allows tests to replace the global [App] instance.
@visibleForTesting
// ignore: non_constant_identifier_names, library_private_types_in_public_api
set App(_App value) => _app = value;

/// Creates a fresh app instance for tests.
///
/// [_App] is library-private; this factory lets tests obtain a constructible
/// instance (via type inference) to assign to the global [App]. Construction
/// is I/O-free: the manager singletons defer their database work to `init()`.
@visibleForTesting
// ignore: library_private_types_in_public_api
_App createAppForTesting() => _App();
