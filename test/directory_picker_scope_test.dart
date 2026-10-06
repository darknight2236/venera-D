import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/io.dart';

/// On iOS a directory chosen through the document picker is only readable while
/// the security scope granted at pick time is active, and the single thing that
/// ends it is `DirectoryPicker`'s finalizer calling the argument-less native
/// `stopAccessingSecurityScopedResource` (which revokes whatever URL the
/// AppDelegate currently holds, then drops it).
///
/// `ImportComic.multiplePdf` / `multipleCbz` keep the picker in a local that is
/// dead as soon as `pickDirectory()` returns, so a collection anywhere inside
/// the import loop revokes the directory the loop is still reading. That is the
/// shape of the iPad report: the first PDF imported, then all 29 remaining
/// files failed instantly with `PathAccessException ... errno = 1` at
/// `PdfComic.import`'s `readAsBytes`, twice in a row over the same file list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('venera/method_channel');
  const revoke = 'stopAccessingSecurityScopedResource';

  late Directory fixture;
  late Directory other;
  late Directory cache;
  late List<MethodCall> calls;
  late List<String> pickedPaths;

  setUp(() async {
    App.debugForceIOS = true;
    calls = <MethodCall>[];
    fixture = await Directory.systemTemp.createTemp('venera_scope_fixture');
    other = await Directory.systemTemp.createTemp('venera_scope_other');
    // The finalizer deletes the picked directory when it lives under the cache
    // path (that is the Android copy-to-cache case); point the cache elsewhere
    // so the fixture survives.
    cache = await Directory.systemTemp.createTemp('venera_scope_cache');
    App.cachePath = cache.path;
    for (var i = 0; i < 3; i++) {
      await File('${fixture.path}${Platform.pathSeparator}book$i.pdf')
          .writeAsBytes(Uint8List(64));
    }
    pickedPaths = [other.path, fixture.path];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getDirectoryPath') {
        return pickedPaths.isNotEmpty
            ? pickedPaths.removeAt(0)
            : fixture.path;
      }
      return null;
    });
  });

  tearDown(() async {
    App.debugForceIOS = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    for (final dir in [fixture, other, cache]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('revoking the security scope must name the directory it revokes', () {
    final source = File('lib/utils/io.dart').readAsStringSync();
    final revokes = RegExp(
      r'invokeMethod\(\s*"stopAccessingSecurityScopedResource"([^;]*)\)',
    ).allMatches(source).toList();

    expect(revokes, isNotEmpty,
        reason: 'expected lib/utils/io.dart to still own the revoke call');
    for (final match in revokes) {
      expect(match.group(1)!.trim(), isNotEmpty,
          reason: 'The native side holds exactly one directory URL, so an '
              'argument-less revoke cancels whichever directory is current - '
              'including one another import is still reading. Pass the path.');
    }
  });

  test("a stale picker's finalizer must not revoke the directory in use",
      () async {
    // The hazard is not the picker of the running import - that one is still
    // referenced by the import's async frame - but the picker left over from an
    // earlier pick. It is garbage, and because the native revoke takes no
    // argument it cancels whatever directory the AppDelegate holds *now*, which
    // is the one the new import is reading. That is the second batch in the
    // iPad log: a fresh pick, then every file failing with EPERM.
    late WeakReference<DirectoryPicker> stale;

    Future<void> earlierPick() async {
      var picker = DirectoryPicker();
      stale = WeakReference(picker);
      await picker.pickDirectory(directAccess: true);
    }

    await earlierPick();

    final inUse = DirectoryPicker();
    final dir = await inUse.pickDirectory(directAccess: true);
    expect(dir, isNotNull);
    final files = (await dir!.list().toList()).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    var collected = false;
    for (var round = 0; round < 60 && !collected; round++) {
      final ballast = <Uint8List>[];
      for (var i = 0; i < 8; i++) {
        ballast.add(Uint8List(2 * 1024 * 1024));
      }
      ballast.clear();
      await Future<void>.delayed(Duration.zero);
      collected = stale.target == null;
    }
    expect(collected, isTrue,
        reason: 'could not make the stale picker collectable, so this run did '
            'not exercise the hazard at all');

    // Still reading the directory the current pick granted.
    for (final file in files) {
      await file.readAsBytes();
    }

    final revokes =
        calls.where((call) => call.method == revoke).toList(growable: false);
    expect(revokes, isNotEmpty,
        reason: 'the stale picker was collected, so its revoke should be here');
    for (final call in revokes) {
      expect(call.arguments, isA<Map>(),
          reason: 'a revoke must name the directory it drops: the native side '
              'grants several directories, and an argument-less revoke cancels '
              'whichever one is current - here the directory still being read');
      expect((call.arguments as Map)['path'], isNot(dir.path),
          reason: 'revoked the directory still in use: ${dir.path}');
    }
    // Keeps the live picker reachable so its own finalizer cannot fire inside
    // this test and be mistaken for the stale one's.
    expect(inUse, isNotNull);
  });

  test('release drops exactly the directory it was granted', () async {
    final picker = DirectoryPicker();
    final dir = await picker.pickDirectory(directAccess: true);
    expect(dir, isNotNull);

    await picker.release();

    final revokes = calls.where((call) => call.method == revoke).toList();
    expect(revokes.length, 1, reason: 'release should revoke once');
    expect((revokes.single.arguments as Map)['path'], dir!.path);

    // And detaching must keep a later collection of the instance from sending a
    // second revoke, which would otherwise drop a newer grant of the same path.
    await picker.release();
    expect(
        calls.where((call) => call.method == revoke).length, 1,
        reason: 'a released picker must not revoke again');
  });
}
