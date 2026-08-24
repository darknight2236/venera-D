import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/reload_gate.dart';

void main() {
  group('ReloadGate', () {
    test('starts idle and grants the first load', () {
      final gate = ReloadGate();
      expect(gate.isLoading, isFalse);
      expect(gate.beginLoad(), isTrue);
      expect(gate.isLoading, isTrue);
    });

    test('rejects a second load while one is in flight', () {
      final gate = ReloadGate();
      expect(gate.beginLoad(), isTrue);
      expect(gate.beginLoad(), isFalse);
      expect(gate.isLoading, isTrue);
    });

    test('endLoad without pending invalidations owes no re-run', () {
      final gate = ReloadGate();
      gate.beginLoad();
      expect(gate.endLoad(), isFalse);
      expect(gate.isLoading, isFalse);
    });

    test('invalidations during a load are coalesced into one re-run (#768)',
        () {
      final gate = ReloadGate();
      gate.beginLoad();
      // A favorite is added while the async list load is in flight.
      expect(gate.beginLoad(), isFalse);
      expect(gate.beginLoad(), isFalse);
      // The load completes: exactly one catch-up reload is owed.
      expect(gate.endLoad(), isTrue);
      // The catch-up load runs and completes cleanly with nothing pending.
      expect(gate.beginLoad(), isTrue);
      expect(gate.endLoad(), isFalse);
    });

    test('a pending flag is consumed by endLoad, not leaked to later loads',
        () {
      final gate = ReloadGate();
      gate.beginLoad();
      gate.beginLoad(); // remembered as pending
      expect(gate.endLoad(), isTrue);
      // A fresh load afterwards starts clean.
      expect(gate.beginLoad(), isTrue);
      expect(gate.endLoad(), isFalse);
    });

    test('idle endLoad is harmless', () {
      final gate = ReloadGate();
      expect(gate.endLoad(), isFalse);
      expect(gate.beginLoad(), isTrue);
    });
  });
}
