import 'package:sqlite3/sqlite3.dart';

/// Checks whether the native sqlite3 library is usable inside `flutter test`.
///
/// sqlite3 3.x loads SQLite through build hooks instead of a hand-picked
/// `DynamicLibrary`, so the test runner's native-assets manifest is the only
/// thing that needs to line up - there is no path to override any more.
///
/// Returns true when sqlite3 is usable. Tests that need sqlite3 should be
/// skipped when this returns false, e.g.:
///
/// ```dart
/// final sqliteAvailable = ensureSqlite3ForTests();
/// test('...', () { ... }, skip: sqliteAvailable ? false : sqlite3SkipReason);
/// ```
bool ensureSqlite3ForTests() {
  if (_configured) return _available;
  _configured = true;

  try {
    sqlite3.version;
    _available = true;
  } catch (_) {
    _available = false;
  }
  return _available;
}

const sqlite3SkipReason = 'native sqlite3 library unavailable in this test run';

bool _configured = false;
bool _available = false;
