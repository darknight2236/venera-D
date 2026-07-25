import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Architecture constraint test: ensures dependency direction rules declared in
/// AGENTS.md are enforced automatically.
///
/// Rules:
/// - lib/foundation/ and lib/network/ must NOT import from lib/pages/ or
///   lib/components/.
/// - Known exemption: network/cloudflare.dart → pages/webview.dart (issue #5).
void main() {
  group('Architecture constraints', () {
    test(
        'lib/foundation/ and lib/network/ do not import from pages or components',
        () {
      final projectRoot = _findProjectRoot();
      final violations = <String>[];

      final dirsToCheck = [
        Directory(p.join(projectRoot, 'lib', 'foundation')),
        Directory(p.join(projectRoot, 'lib', 'network')),
      ];

      for (final dir in dirsToCheck) {
        if (!dir.existsSync()) continue;
        final dartFiles = dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'));

        for (final file in dartFiles) {
          final relativePath =
              p.relative(file.path, from: projectRoot).replaceAll('\\', '/');

          // Known exemption: network/cloudflare.dart → pages/webview.dart
          if (relativePath == 'lib/network/cloudflare.dart') continue;

          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trim();
            if (!line.startsWith('import ')) continue;

            if (_isForbiddenImport(line)) {
              violations.add('$relativePath:${i + 1}: $line');
            }
          }
        }
      }

      if (violations.isNotEmpty) {
        fail(
          'Architecture violation: foundation/network must not import from '
          'pages/components.\n'
          'Found ${violations.length} violation(s):\n'
          '  ${violations.join('\n  ')}',
        );
      }
    });
  });
}

/// Checks if an import line references pages/ or components/ (forbidden layers).
bool _isForbiddenImport(String importLine) {
  // Package imports: import 'package:venera/pages/...' or 'package:venera/components/...'
  if (importLine.contains('package:venera/pages/') ||
      importLine.contains('package:venera/components/')) {
    return true;
  }

  // Relative imports that reach into pages/ or components/
  final relativePattern =
      RegExp(r'''['"]\.\..*/(pages|components)/''');
  if (relativePattern.hasMatch(importLine)) {
    return true;
  }

  return false;
}

/// Walks up from the current working directory to find the project root
/// (identified by pubspec.yaml).
String _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      // Fallback: assume cwd is the project root
      return Directory.current.path;
    }
    dir = parent;
  }
}
