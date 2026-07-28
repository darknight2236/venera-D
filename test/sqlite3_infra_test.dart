import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'helpers/sqlite3_test_setup.dart';

void main() {
  final sqliteAvailable = ensureSqlite3ForTests();

  group('sqlite3 test infrastructure', () {
    test(
      'native library loads and an in-memory database works',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        db.execute("INSERT INTO t (name) VALUES ('venera')");
        final rows = db.select('SELECT name FROM t');

        expect(rows, hasLength(1));
        expect(rows.first['name'], 'venera');
      },
      skip: sqliteAvailable ? false : sqlite3SkipReason,
    );
  });
}
