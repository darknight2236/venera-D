import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  group('Appdata serialization', () {
    test('toJson/loadFromJson round-trip preserves settings and history', () {
      final source = Appdata.forTesting();
      source.settings['language'] = 'zh-CN';
      source.settings['preloadImageCount'] = 8;
      source.settings['theme_mode'] = 'dark';
      source.searchHistory.addAll(['search-a', 'search-b']);

      // Simulate persistence: cross the real JSON encode/decode boundary so
      // non-serializable values would surface here.
      final decoded =
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;

      final restored = Appdata.forTesting();
      restored.loadFromJson(decoded);

      expect(restored.settings['language'], 'zh-CN');
      expect(restored.settings['preloadImageCount'], 8);
      expect(restored.settings['theme_mode'], 'dark');
      expect(restored.searchHistory, ['search-a', 'search-b']);
    });

    test('loadFromJson skips null setting values', () {
      final restored = Appdata.forTesting();
      final defaultLanguage = restored.settings['language'];

      restored.loadFromJson({
        'settings': {'language': null, 'theme_mode': 'light'},
        'searchHistory': <String>[],
      });

      // A null value must not overwrite the existing/default setting,
      // matching the guard in the original doInit() logic.
      expect(restored.settings['language'], defaultLanguage);
      expect(restored.settings['theme_mode'], 'light');
    });
  });

  group('appdata global seam', () {
    test('global appdata can be replaced for testing', () {
      final fake = Appdata.forTesting();
      fake.settings['language'] = 'en-US';
      appdata = fake;
      addTearDown(() => appdata = Appdata.forTesting());

      expect(appdata.settings['language'], 'en-US');
      expect(identical(appdata, fake), isTrue);
    });
  });
}
