import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/translations.dart';

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

  group('ImportComic.wrapPasswordProvider', () {
    test('toasts "Incorrect password" only after the first attempt', () async {
      final messages = <String>[];
      final answers = <String?>['wrong', 'right'];
      var i = 0;
      final importer = ImportComic(
        showMessage: messages.add,
        showLoading: ({message, allowCancel = true, onCancel}) => null,
        passwordProvider: (_) async => answers[i++],
      );

      final wrapped = importer.wrapPasswordProvider(importer.passwordProvider!);
      expect(await wrapped('f.pdf'), 'wrong');
      expect(messages, isEmpty); // first prompt follows a silent empty attempt
      expect(await wrapped('f.pdf'), 'right');
      expect(messages.length, 1); // second prompt reports the failed attempt
    });

    test('passes the file name through to the inner provider', () async {
      String? seen;
      final importer = ImportComic(
        showMessage: (_) {},
        showLoading: ({message, allowCancel = true, onCancel}) => null,
        passwordProvider: (name) async {
          seen = name;
          return 'pw';
        },
      );

      await importer.wrapPasswordProvider(importer.passwordProvider!)('x.pdf');
      expect(seen, 'x.pdf');
    });
  });
}
