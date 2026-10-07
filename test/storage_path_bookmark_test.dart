import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

/// On iOS a directory chosen outside the app container is only reachable while
/// the security scope is active, and that scope does not survive a relaunch.
/// `setNewPath` used to persist nothing but the bare path in `local_path`, so
/// after a restart `LocalManager.init` could not see the directory it had just
/// been pointed at - the comics looked deleted, because the copy in
/// [LocalManager.setNewPath] had already emptied the old location.
///
/// The fix is a `URL.bookmarkData` round trip: the picker hands back a
/// base64 security-scoped bookmark next to the path, `setNewPath` stores it,
/// and `init` claims it before touching the directory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('venera/method_channel');
  const claim = 'startAccessingSecurityScopedBookmark';

  late Directory dataPath;
  late Directory source;
  late Directory target;
  late LocalManager manager;
  late List<MethodCall> calls;

  /// base64 bookmark -> the path the native side resolves it to. A missing key
  /// or a null value both stand for "the grant could not be restored".
  late Map<String, String?> resolved;

  /// What the target directory looked like at the moment the claim arrived -
  /// used to check the claim runs before anything is copied into it.
  List<String> targetAtClaim = [];

  File storedPath() => File(FilePath.join(dataPath.path, 'local_path'));
  File storedBookmark() => File(FilePath.join(dataPath.path, 'local_bookmark'));

  setUp(() async {
    App.debugForceIOS = true;
    dataPath = await Directory.systemTemp.createTemp('venera_bm_data');
    source = await Directory.systemTemp.createTemp('venera_bm_source');
    target = await Directory.systemTemp.createTemp('venera_bm_target');
    App.dataPath = dataPath.path;
    // findDefaultPath() on iOS returns dataPath/local when it already holds
    // something, which keeps path_provider out of these tests.
    final fallback = Directory(FilePath.join(dataPath.path, 'local'))
      ..createSync();
    File(FilePath.join(fallback.path, 'keep.txt')).writeAsStringSync('x');

    calls = [];
    resolved = {};
    targetAtClaim = [];
    manager = LocalManager.forTesting(source.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == claim) {
        targetAtClaim = target.listSync().map((e) => e.path).toList();
        final bookmark = (call.arguments as Map)['bookmark'] as String;
        final path = resolved[bookmark];
        return path == null ? null : {'path': path};
      }
      return null;
    });
  });

  tearDown(() async {
    App.debugForceIOS = false;
    LocalManager.debugSetInstance(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    for (final dir in [dataPath, source, target]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('resolveStoredPath', () {
    test('claims the stored bookmark before checking the directory', () async {
      storedPath().writeAsStringSync(source.path);
      storedBookmark().writeAsStringSync('BM-1');
      resolved['BM-1'] = source.path;

      expect(await manager.resolveStoredPath(), source.path);
      expect(calls.map((call) => call.method), [claim]);
      expect((calls.single.arguments as Map)['bookmark'], 'BM-1');
    });

    test('does not call the platform when no bookmark was stored', () async {
      storedPath().writeAsStringSync(source.path);

      expect(await manager.resolveStoredPath(), source.path);
      expect(calls, isEmpty);
    });

    test('recovers the directory through the bookmark after a move', () async {
      var moved = FilePath.join(target.path, 'renamed');
      Directory(moved).createSync();
      storedPath().writeAsStringSync(FilePath.join(source.path, 'gone'));
      storedBookmark().writeAsStringSync('BM-2');
      resolved['BM-2'] = moved;

      expect(await manager.resolveStoredPath(), moved);
    });

    test('falls back to the default path without a bookmark', () async {
      storedPath().writeAsStringSync(FilePath.join(source.path, 'gone'));

      expect(await manager.resolveStoredPath(),
          FilePath.join(dataPath.path, 'local'));
    });

    test('ignores a bookmark pointing at a directory that is gone', () async {
      storedPath().writeAsStringSync(FilePath.join(source.path, 'gone'));
      storedBookmark().writeAsStringSync('BM-3');
      resolved['BM-3'] = FilePath.join(target.path, 'never-existed');

      expect(await manager.resolveStoredPath(),
          FilePath.join(dataPath.path, 'local'),
          reason: 'creating the folder the stale bookmark names would leave the '
              'comics behind an empty path');
    });
  });

  group('setNewPath', () {
    setUp(() async {
      File(FilePath.join(source.path, 'comic.pdf')).writeAsStringSync('data');
      resolved['BM-NEW'] = target.path;
    });

    test('stores the bookmark beside the path and claims it first', () async {
      expect(await manager.setNewPath(target.path, bookmark: 'BM-NEW'), null);

      // The grant has to exist before the copy writes into a directory that is
      // outside the container, otherwise the copy throws EPERM.
      expect(targetAtClaim, isEmpty,
          reason: 'the bookmark must be claimed before anything is copied');
      expect(storedPath().readAsStringSync(), target.path);
      expect(storedBookmark().readAsStringSync(), 'BM-NEW');
      expect(File(FilePath.join(target.path, 'comic.pdf')).readAsStringSync(),
          'data');
      expect(source.listSync(), isEmpty);
    });

    test('stops on a claim failure without rewriting anything', () async {
      storedPath().writeAsStringSync(source.path);
      storedBookmark().writeAsStringSync('BM-OLD');
      resolved['BM-OLD'] = source.path;
      resolved.remove('BM-NEW'); // the native side cannot restore this grant

      var message = await manager.setNewPath(target.path, bookmark: 'BM-NEW');

      expect(message, "Could not access the selected directory");
      expect(storedPath().readAsStringSync(), source.path);
      expect(storedBookmark().readAsStringSync(), 'BM-OLD');
      expect(File(FilePath.join(source.path, 'comic.pdf')).existsSync(), isTrue);
      expect(target.listSync(), isEmpty);
    });

    test('drops the old bookmark when the new path needs no grant', () async {
      storedBookmark().writeAsStringSync('BM-OLD');

      expect(await manager.setNewPath(target.path), null);

      expect(storedBookmark().existsSync(), isFalse,
          reason: 'a leftover bookmark would claim access to the directory the '
              'path no longer points at');
      expect(storedPath().readAsStringSync(), target.path);
    });

    test('keeps the bookmark when the target is rejected', () async {
      storedPath().writeAsStringSync(source.path);
      storedBookmark().writeAsStringSync('BM-OLD');
      resolved['BM-OLD'] = source.path;
      File(FilePath.join(target.path, 'foreign.txt')).writeAsStringSync('x');

      expect(await manager.setNewPath(target.path, bookmark: 'BM-NEW'),
          'Directory is not empty');
      expect(storedBookmark().readAsStringSync(), 'BM-OLD',
          reason: 'an early return must not drop the grant for the path still '
              'in use');
      expect(storedPath().readAsStringSync(), source.path);
    });
  });

  test('the iOS picker must hand back a bookmark with the directory', () {
    var picker = File('ios/Runner/DirectoryPicker.swift').readAsStringSync();
    expect(picker, contains('bookmarkData'),
        reason: 'the storage path can only be reopened after a relaunch from '
            'bookmark data created while the pick was still live');
    expect(picker, contains('startAccessingSecurityScopedResource'),
        reason: 'bookmark data is only security-scoped if the URL was claimed');
  });

  test('macOS must reopen the storage path through a security-scoped bookmark',
      () {
    var app = File('macos/Runner/AppDelegate.swift').readAsStringSync();
    expect(app, contains('case "selectDirectory"'),
        reason: 'the settings page picks through the platform channel on macOS '
            'too; file_selector never hands back the URL to bookmark');
    expect(app, contains('bookmarkData'),
        reason: 'a sandboxed macOS app loses the open panel grant when it '
            'quits, so the pick has to persist a bookmark');
    expect(app, contains('.withSecurityScope'),
        reason: 'only a security-scoped bookmark survives the sandbox: '
            'plain bookmark data resolves but grants no access');
    expect(app, contains('resolvingBookmarkData'),
        reason: 'the stored bookmark has to be claimed at launch, before the '
            'path is used');
    expect(app, contains('case "startAccessingSecurityScopedBookmark"'),
        reason: 'the launch-time claim arrives on its own channel method');
    expect(app, contains('startAccessingSecurityScopedResource'));
  });
}
