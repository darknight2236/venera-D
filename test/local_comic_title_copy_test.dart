import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'helpers/sqlite3_test_setup.dart';

/// Local comics go straight into the reader, so there is no detail page to
/// copy a title from - and on a touch screen the local page's own popup menu
/// (which does carry "Copy Title") is out of reach, because a long press there
/// starts multi-selection instead. Both gaps are covered by one entry that the
/// selection menu and the home page's thumbnail menu share.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sqliteAvailable = ensureSqlite3ForTests();
  late Directory tmp;
  late List<String> copied;
  late Comic comic;

  setUpAll(() async {
    appdata = Appdata.forTesting();
    // An English locale makes `.tl` identity, so assertions can use the keys.
    appdata.settings['language'] = 'en-US';
    App = createAppForTesting();
    await AppTranslation.init();
  });

  setUp(() {
    copied = [];
    tmp = Directory.systemTemp.createTempSync('local_title');
    LocalManager.debugSetInstance(LocalManager.forTesting(tmp.path));
    LocalFavoritesManager.debugSetInstance(LocalFavoritesManager.forTesting());
    comic = const Comic('Everlasting Summer', 'cover.jpg', 'cid1', null, null,
        '', 'local', null, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    LocalFavoritesManager.debugSetInstance(null);
    LocalManager.debugSetInstance(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LocalComic localComic() => LocalComic(
        id: 'cid1',
        title: 'Everlasting Summer',
        subtitle: '',
        tags: const [],
        directory: 'comic1',
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  group('copyTitleEntry', () {
    testWidgets('copies the title and says so', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ));

      var entry = copyTitleEntry(comic, ctx);
      entry.onClick();
      // The toast schedules its own dismissal timer; let it fire so the test
      // does not end with a pending timer.
      await tester.pump(const Duration(seconds: 3));

      expect(entry.text, 'Copy Title');
      expect(copied, ['Everlasting Summer']);
    });
  });

  group('SimpleComicTile', () {
    testWidgets('opens its menu on a long press, not on a tap',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SimpleComicTile(
              comic: comic,
              onTap: () => taps++,
              menuOptions: [
                MenuEntry(text: 'Marker', onClick: () {}),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.byType(SimpleComicTile));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(find.text('Marker'), findsNothing);

      await tester.longPress(find.byType(SimpleComicTile));
      await tester.pumpAndSettle();
      expect(find.text('Marker'), findsOneWidget,
          reason: 'the thumbnail needs the same long-press menu the other '
              'comic tiles have');

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(taps, 1,
          reason: 'opening the menu must not also open the comic');
    });

    testWidgets('without menuOptions a long press stays a plain tap',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SimpleComicTile(comic: comic, onTap: () => taps++),
          ),
        ),
      ));

      await tester.longPress(find.byType(SimpleComicTile));
      await tester.pumpAndSettle();

      expect(taps, 1,
          reason: 'with no menu to open, the tile keeps the tap-only gesture '
              'it has always had');
    });
  });

  group('LocalComicsPage selection menu', () {
    testWidgets('offers Copy Title for a single selection', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ));

      var entries = singleSelectionEntries(localComic(), ctx);

      var copy = entries.singleWhere((entry) => entry.text == 'Copy Title');
      copy.onClick();
      await tester.pump(const Duration(seconds: 3));
      expect(copied, ['Everlasting Summer'],
          reason: 'the selection menu is the touch-reachable stand-in for the '
              'tile popup that multi-select replaces');
    }, skip: !sqliteAvailable);
  });
}
