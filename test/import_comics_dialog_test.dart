import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/utils/translations.dart';

/// The import chooser's option list and its two conditional rows are driven
/// entirely by `type`. Adding the PDF entries renumbered EhViewer/Restore, so
/// every index-sensitive condition had to move with it - these tests pin that
/// mapping, which is the part a manual click-through is worst at catching.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodLabels = [
    'Single Comic',
    'Multiple Comics',
    'An archive file',
    'Multiple archive files',
    'A PDF file',
    'Multiple PDF files',
    'EhViewer downloads',
    'Restore local downloads',
  ];

  const infoTexts = [
    'Select a directory which contains the comic files.',
    'Select a directory which contains the comic directories.',
    'Select an archive file (cbz, zip, 7z, cb7)',
    'Select a directory which contains multiple archive files.',
    'Select a PDF file (image-based comics).',
    'Select a directory which contains PDF files.',
    'Select an EhViewer database and a download folder.',
    'Scan the current local path and restore the local database.',
  ];

  // Rows hidden for the folder-less and always-copy flows.
  const hideFavoritesFor = {6, 7};
  const hideCopyFor = {2, 3, 4, 5, 7};

  setUpAll(() async {
    // An English locale makes `.tl` identity (there is no en_US section), so
    // assertions can use the key strings directly.
    appdata = Appdata.forTesting();
    appdata.settings['language'] = 'en-US';
    App = createAppForTesting();
    await AppTranslation.init();
    LocalFavoritesManager.debugSetInstance(LocalFavoritesManager.forTesting());
    LocalFavoritesManager().createFolder('Books');
  });

  tearDownAll(() => LocalFavoritesManager.debugSetInstance(null));

  Future<void> pumpDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Present it the way the app does, through showDialog: ContentDialog
    // relies on the Dialog route's own width constraints, so pumping it
    // straight into a Scaffold body lays it out at a size it never sees in
    // practice and overflows its action row.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const ImportComicsWidget(),
                );
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists all eight import methods in order', (tester) async {
    await pumpDialog(tester);

    final tiles = find.byType(RadioListTile<int>);
    expect(tiles, findsNWidgets(methodLabels.length));
    for (var i = 0; i < methodLabels.length; i++) {
      expect(find.text(methodLabels[i]), findsOneWidget,
          reason: 'method $i should read "${methodLabels[i]}"');
    }
  });

  testWidgets('each index shows its own help text, and only that one',
      (tester) async {
    await pumpDialog(tester);

    for (var type = 0; type < methodLabels.length; type++) {
      await tester.tap(find.byType(RadioListTile<int>).at(type));
      await tester.pumpAndSettle();

      expect(find.text(infoTexts[type]), findsOneWidget,
          reason: 'type $type should explain itself');
      for (final other in infoTexts.where((t) => t != infoTexts[type])) {
        expect(find.text(other), findsNothing,
            reason: 'type $type must not still show "$other"');
      }
    }
  });

  testWidgets('the favourites-row visibility matches its condition',
      (tester) async {
    await pumpDialog(tester);

    for (var type = 0; type < methodLabels.length; type++) {
      await tester.tap(find.byType(RadioListTile<int>).at(type));
      await tester.pumpAndSettle();

      final found = tester.any(find.text('Add to favorites'));
      expect(found, !hideFavoritesFor.contains(type),
          reason: 'favourites row at type $type '
              '(${hideFavoritesFor.contains(type) ? 'should be hidden' : 'should show'})');
    }
  });

  testWidgets('the copy-to-local-path row stays off the copy-always flows',
      (tester) async {
    await pumpDialog(tester);
    // The row is platform-gated; on the test host this mirrors the widget.
    final platformAllows = !App.isIOS && !App.isMacOS;

    for (var type = 0; type < methodLabels.length; type++) {
      await tester.tap(find.byType(RadioListTile<int>).at(type));
      await tester.pumpAndSettle();

      final found = tester.any(find.text('Copy to app local path'));
      expect(found, platformAllows && !hideCopyFor.contains(type),
          reason: 'copy row at type $type');
    }
  });

  testWidgets('selecting Restore clears the chosen folder', (tester) async {
    await pumpDialog(tester);

    final state =
        tester.state<ImportComicsWidgetState>(find.byType(ImportComicsWidget));

    // Select renders its values only inside a popup, so drive the field the
    // picker would have written to rather than fighting the overlay.
    await tester.tap(find.byType(RadioListTile<int>).at(0));
    await tester.pumpAndSettle();
    state.selectedFolder = 'Books';
    await tester.pumpAndSettle();
    expect(state.selectedFolder, isNotNull);

    await tester.tap(find.byType(RadioListTile<int>).at(7));
    await tester.pumpAndSettle();
    expect(state.selectedFolder, isNull);
  });

  testWidgets('choosing any other option leaves the chosen folder alone',
      (tester) async {
    await pumpDialog(tester);

    final state =
        tester.state<ImportComicsWidgetState>(find.byType(ImportComicsWidget));
    state.selectedFolder = 'Books';
    await tester.pumpAndSettle();

    // The reset must be specific to Restore; the PDF options in particular
    // sit right where the folder logic used to be untouched.
    for (final type in [1, 2, 3, 4, 5, 6]) {
      await tester.tap(find.byType(RadioListTile<int>).at(type));
      await tester.pumpAndSettle();
      expect(state.selectedFolder, 'Books',
          reason: 'type $type should not clear the folder');
    }
  });
}
