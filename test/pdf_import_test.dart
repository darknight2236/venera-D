import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/pdf_import.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('PdfComic.import', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pdf_import');
      App.cachePath = tmp.path;
      App.dataPath = tmp.path;
      final localPath = FilePath.join(tmp.path, 'local');
      Directory(localPath).createSync(recursive: true);
      LocalManager.debugSetInstance(LocalManager.forTesting(localPath));
    });

    tearDown(() {
      LocalManager.debugSetInstance(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File fixture(String name) => File('test/fixtures/pdf/$name');

    test('imports the plain JPEG fixture end to end', () async {
      final comic = await PdfComic.import(fixture('plain_jpeg.pdf'));

      expect(comic.title, 'plain_jpeg');
      expect(comic.cover, 'cover.jpg');
      expect(comic.hasChapters, isFalse);
      final dir = Directory(FilePath.join(LocalManager().path, comic.directory));
      expect(dir.existsSync(), isTrue);
      expect(File(FilePath.join(dir.path, 'cover.jpg')).existsSync(), isTrue);
      // Two page images: the first becomes cover.jpg, the second 1.jpg.
      expect(File(FilePath.join(dir.path, '1.jpg')).existsSync(), isTrue);
      // The transient cache directory is cleaned up.
      expect(
          Directory(FilePath.join(tmp.path, 'pdf_import')).existsSync(), isFalse);
    });

    test('imported pages are real, decodable JPEGs', () async {
      final comic = await PdfComic.import(fixture('plain_jpeg.pdf'));
      final dir = Directory(FilePath.join(LocalManager().path, comic.directory));
      for (final name in ['cover.jpg', '1.jpg']) {
        final bytes = File(FilePath.join(dir.path, name)).readAsBytesSync();
        // JPEG SOI marker followed by a segment header - not garbage bytes.
        expect(bytes[0], 0xFF);
        expect(bytes[1], 0xD8);
        expect(bytes.length, greaterThan(100));
      }
    });

    test('imports an encrypted (R6) PDF via a password provider', () async {
      final comic = await PdfComic.import(
        fixture('enc_aes256_r6.pdf'),
        passwordProvider: (_) async => 'user123',
      );

      expect(comic.title, 'enc_aes256_r6');
      expect(comic.cover, 'cover.jpg');
      final dir = Directory(FilePath.join(LocalManager().path, comic.directory));
      final bytes =
          File(FilePath.join(dir.path, 'cover.jpg')).readAsBytesSync();
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
    });

    test('a cancelled import leaves no partial comic directory', () async {
      await expectLater(
        PdfComic.import(
          fixture('enc_rc4_128.pdf'),
          passwordProvider: (_) async => null,
        ),
        throwsA(isA<PdfCancelledException>()),
      );
      expect(
          Directory(FilePath.join(tmp.path, 'pdf_import')).existsSync(), isFalse);
      expect(Directory(FilePath.join(LocalManager().path, 'enc_rc4_128'))
          .existsSync(), isFalse);
    });

    test('a duplicate title is rejected before writing anything', () async {
      await LocalManager().add(LocalComic(
        id: LocalManager().findValidId(ComicType.local),
        title: 'plain_jpeg',
        subtitle: '',
        tags: const [],
        directory: 'plain_jpeg',
        chapters: null,
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.now(),
      ));

      await expectLater(
        PdfComic.import(fixture('plain_jpeg.pdf')),
        throwsA(isA<Exception>()),
      );
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}
