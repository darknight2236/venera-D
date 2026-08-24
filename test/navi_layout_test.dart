import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/navi_layout.dart';

void main() {
  group('NaviLayout.showsTopAndBottomBars', () {
    test('narrow mode (bottom navigation) shows the top bar', () {
      expect(NaviLayout.showsTopAndBottomBars(0), isTrue);
      expect(NaviLayout.showsTopAndBottomBars(1), isTrue);
      expect(NaviLayout.showsTopAndBottomBars(1.9), isTrue);
    });

    test('side bar modes hide the top/bottom bars', () {
      expect(NaviLayout.showsTopAndBottomBars(2), isFalse);
      expect(NaviLayout.showsTopAndBottomBars(2.5), isFalse);
      expect(NaviLayout.showsTopAndBottomBars(3), isFalse);
    });
  });

  group('NaviLayout.sidebarPageTitleOpacity', () {
    test('folded side bar shows the page title fully opaque (#738)', () {
      expect(NaviLayout.sidebarPageTitleOpacity(2), 1.0);
    });

    test('the title fades out while the bar expands toward mode 3', () {
      expect(NaviLayout.sidebarPageTitleOpacity(2.25), closeTo(0.75, 1e-9));
      expect(NaviLayout.sidebarPageTitleOpacity(2.5), closeTo(0.5, 1e-9));
      expect(NaviLayout.sidebarPageTitleOpacity(2.99), closeTo(0.01, 1e-9));
    });

    test('expanded side bar hides the title (nav items carry labels)', () {
      expect(NaviLayout.sidebarPageTitleOpacity(3), 0.0);
    });

    test('narrow mode hides the title (the top bar shows it instead)', () {
      expect(NaviLayout.sidebarPageTitleOpacity(0), 0.0);
      expect(NaviLayout.sidebarPageTitleOpacity(1), 0.0);
      expect(NaviLayout.sidebarPageTitleOpacity(1.9), 0.0);
    });
  });
}
