import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `sqlite3.fromPointer(...)` in lib/ runs inside `Isolate.run` while the
/// main isolate keeps using the same connection. sqlite3 3.x attaches a native
/// finalizer calling `sqlite3_close_v2` to any wrapper that is not `borrowed`,
/// so isolate teardown closes a connection still in use and the next statement
/// fails with SqliteException(21) SQLITE_MISUSE. See the behavioral proof in
/// test/cache_manager_test.dart ("the scan must not close the connection ...").
void main() {
  test('every fromPointer wrapper is borrowed', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('fromPointer(')) {
          continue;
        }
        // The call may wrap onto the following lines; collect until it closes.
        final statement = lines.skip(i).take(3).join(' ');
        if (!statement.contains('borrowed: true')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'wrap foreign sqlite3 handles with borrowed: true, or isolate '
          'teardown closes the parent connection (SQLITE_MISUSE). Reproduced '
          'in test/cache_manager_test.dart.',
    );
  });
}
