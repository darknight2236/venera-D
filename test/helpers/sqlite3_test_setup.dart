import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Makes the native sqlite3 library loadable inside the `flutter test` VM.
///
/// The test VM does not bundle the native library that
/// `sqlite3_flutter_libs` ships with app builds, so on Windows
/// `DynamicLibrary.open('sqlite3.dll')` fails with error 126 unless the DLL
/// is on PATH. This helper points the sqlite3 package at a usable library:
///
/// - Windows: the DLL produced by a previous `flutter build windows` under
///   `build/windows/`.
/// - Linux: falls back to the runtime `libsqlite3.so.0` when the dev
///   symlink `libsqlite3.so` is absent (typical on CI runners).
/// - macOS: the system `libsqlite3.dylib` works out of the box.
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

  if (Platform.isWindows) {
    const candidates = [
      'build/windows/x64/runner/Release/sqlite3.dll',
      'build/windows/x64/runner/Debug/sqlite3.dll',
      'build/windows/x64/plugins/sqlite3_flutter_libs/Release/sqlite3.dll',
      'build/windows/x64/plugins/sqlite3_flutter_libs/Debug/sqlite3.dll',
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        final path = file.absolute.path;
        open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(path),
        );
        break;
      }
    }
  } else if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      try {
        return DynamicLibrary.open('libsqlite3.so');
      } on ArgumentError {
        return DynamicLibrary.open('libsqlite3.so.0');
      }
    });
  }

  try {
    sqlite3.version;
    _available = true;
  } catch (_) {
    _available = false;
  }
  return _available;
}

const sqlite3SkipReason =
    'native sqlite3 library not found; on Windows run '
    '`flutter build windows` once to produce build/windows/**/sqlite3.dll';

bool _configured = false;
bool _available = false;
