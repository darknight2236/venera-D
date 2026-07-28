import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';

void main() {
  test('App.version matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+?)\+',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');

    final pubspecVersion = match!.group(1);
    expect(
      App.version,
      pubspecVersion,
      reason:
          'lib/foundation/app.dart App.version must be kept in sync with '
          'pubspec.yaml when bumping the release version',
    );
  });
}
