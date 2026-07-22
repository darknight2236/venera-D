import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  group('App seam', () {
    test('global App can be replaced for testing', () {
      final fake = createAppForTesting();
      App = fake;
      addTearDown(() => App = createAppForTesting());

      expect(identical(App, fake), isTrue);
    });

    test('App.locale parses a non-system language from appdata', () {
      final data = Appdata.forTesting();
      data.settings['language'] = 'zh-CN';
      appdata = data;
      addTearDown(() => appdata = Appdata.forTesting());

      App = createAppForTesting();
      addTearDown(() => App = createAppForTesting());

      // 'zh-CN' must be parsed into Locale('zh', 'CN') without touching the
      // platform dispatcher (the non-'system' branch is pure).
      expect(App.locale, const Locale('zh', 'CN'));
    });
  });
}
