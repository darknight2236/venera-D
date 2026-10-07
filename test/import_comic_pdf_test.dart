import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/translations.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // `.tl` reads a late static populated from the bundled asset, and
    // resolves the language through appdata - both are uninitialized here
    // otherwise, so error mapping cannot be exercised without them.
    appdata = Appdata.forTesting();
    App = createAppForTesting();
    await AppTranslation.init();
  });

  group('pdfErrorMessage', () {
    test('maps known PDF errors to non-empty user-facing strings', () {
      expect(pdfErrorMessage(PdfNoImagesException()), isNotEmpty);
      expect(pdfErrorMessage(PdfUnsupportedEncodingException(2, 'JPXDecode')),
          isNotEmpty);
      expect(pdfErrorMessage(const PdfEncryptedException()), isNotEmpty);
    });

    test('names the page and encoding for an unsupported encoding', () {
      final msg = pdfErrorMessage(PdfUnsupportedEncodingException(7, 'JBIG2Decode'));
      expect(msg, contains('7'));
      expect(msg, contains('JBIG2Decode'));
    });

    test('passes through unrelated exceptions via toString', () {
      expect(pdfErrorMessage(Exception('boom')), 'Exception: boom');
    });
  });

  group('ImportComic.multiplePdf', () {
    final sqliteAvailable = ensureSqlite3ForTests();
    const channel = MethodChannel('venera/method_channel');
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pdf_batch');
      App.cachePath = tmp.path;
      App.dataPath = tmp.path;
      final localPath = FilePath.join(tmp.path, 'local');
      Directory(localPath).createSync(recursive: true);
      LocalManager.debugSetInstance(LocalManager.forTesting(localPath));
      // Routes DirectoryPicker through the channel mock below instead of
      // file_selector, which has no implementation in a test host.
      App.debugForceIOS = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDirectoryPath') return 'test/fixtures/pdf';
        return null;
      });
    });

    tearDown(() {
      App.debugForceIOS = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      LocalManager.debugSetInstance(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('a folder of encrypted PDFs sharing one password prompts once',
        () async {
      final prompts = <String>[];
      final importer = ImportComic(
        showMessage: (_) {},
        showLoading: ({message, allowCancel = true, onCancel}) =>
            _LoadingController(),
        passwordProvider: (fileName) async {
          prompts.add(fileName);
          return 'user123';
        },
      );

      expect(await importer.multiplePdf(), isTrue);

      expect(prompts.length, 1,
          reason: 'the three encrypted fixtures share user123, so only the '
              'first of them may ask');
      expect(prompts.single, contains('enc_'),
          reason: 'the plain and owner-only fixtures open without a password');
      expect(LocalManager().getComics(LocalSortType.name).length, 5,
          reason: 'every fixture in the folder was imported');
    }, skip: sqliteAvailable ? false : sqlite3SkipReason);
  });
}

class _LoadingController {
  void close() {}
}
