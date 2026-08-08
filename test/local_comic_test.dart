import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('LocalComic data correctness', () {
    group('fromRow', () {
      late Database db;

      setUp(() {
        db = sqlite3.openInMemory();
        // Column order must match LocalComic.fromRow (row[0..9]).
        db.execute('''
          create table comics (
            id text, title text, subtitle text, tags text, directory text,
            chapters text, cover text, type int, downloadedChapters text,
            created_at int
          );
        ''');
      });

      tearDown(() => db.dispose());

      test('restores row including JSON-encoded tags and chapters', () {
        db.execute(
          'insert into comics values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'cid1',
            '本地漫画',
            '副标题',
            jsonEncode(['tag1', 'tag2']),
            'comic_dir',
            jsonEncode({'ch1': '第1话', 'ch2': '第2话'}),
            'cover.jpg',
            ComicType.local.value,
            jsonEncode(['ch1']),
            1750000000000,
          ],
        );
        var row = db.select('select * from comics').first;

        var comic = LocalComic.fromRow(row);

        expect(comic.id, 'cid1');
        expect(comic.title, '本地漫画');
        expect(comic.subtitle, '副标题');
        expect(comic.tags, ['tag1', 'tag2']);
        expect(comic.directory, 'comic_dir');
        expect(comic.chapters, isNotNull);
        expect(comic.chapters!.ids.toList(), ['ch1', 'ch2']);
        expect(comic.cover, 'cover.jpg');
        expect(comic.comicType, ComicType.local);
        expect(comic.downloadedChapters, ['ch1']);
        expect(comic.createdAt.millisecondsSinceEpoch, 1750000000000);
      });

      test('tolerates JSON-encoded null chapters', () {
        // LocalManager stores jsonEncode(chapters); for a chapterless comic
        // that is the string "null", not a SQL NULL.
        db.execute(
          'insert into comics values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          ['cid1', 't', 's', jsonEncode([]), 'd', jsonEncode(null), 'c.jpg',
              ComicType.local.value, jsonEncode([]), 0],
        );

        var comic = LocalComic.fromRow(db.select('select * from comics').first);

        expect(comic.hasChapters, isFalse);
        expect(comic.chapters, isNull);
      });
    });

    group('toJson', () {
      test('serializes core fields for sync', () {
        var comic = LocalComic(
          id: 'cid1',
          title: '本地漫画',
          subtitle: '副标题',
          tags: ['tag1'],
          directory: 'd',
          chapters: null,
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

        var json = comic.toJson();

        expect(json['title'], '本地漫画');
        expect(json['cover'], 'cover.jpg');
        expect(json['id'], 'cid1');
        expect(json['subTitle'], '副标题');
        expect(json['tags'], ['tag1']);
        expect(json['sourceKey'], 'local');
        expect(json.containsKey('chapters'), isTrue);
      });
    });

    test('sourceKey derives from comicType', () {
      var local = LocalComic(
        id: 'i', title: 't', subtitle: '', tags: const [], directory: 'd',
        chapters: null, cover: 'c', comicType: ComicType.local,
        downloadedChapters: const [], createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(local.sourceKey, 'local');
    });
  }, skip: sqliteAvailable ? false : sqlite3SkipReason);
}