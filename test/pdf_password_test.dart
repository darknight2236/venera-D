import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/pdf/security.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/pdf/$name').readAsBytesSync();

/// Fixes the contract the import UI builds against (spec 6.3): the parser
/// tries the empty password silently, re-asks on a wrong guess, treats a null
/// return as a cancel, and hands the provider the file name for its title.
void main() {
  group('PdfPasswordProvider contract', () {
    test('retries the provider after a wrong password, then succeeds',
        () async {
      var calls = 0;
      final images = await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        passwordProvider: (_) async {
          calls++;
          return calls == 1 ? 'wrong' : 'user123';
        },
      ).toList();
      expect(images.length, 2);
      // One silent empty-password attempt precedes these two calls.
      expect(calls, 2);
    });

    test('cancel after a wrong password throws PdfCancelledException',
        () async {
      var calls = 0;
      await expectLater(
        extractPdfImages(
          _fixture('enc_rc4_128.pdf'),
          passwordProvider: (_) async {
            calls++;
            return calls == 1 ? 'wrong' : null;
          },
        ).toList(),
        throwsA(isA<PdfCancelledException>()),
      );
      expect(calls, 2);
    });

    test('owner-only PDF never invokes the provider', () async {
      final images = await extractPdfImages(
        _fixture('owner_only.pdf'),
        passwordProvider: (_) async =>
            throw StateError('provider must not be called for empty password'),
      ).toList();
      expect(images.length, 2);
    });

    test('provider receives the file name for the dialog title', () async {
      final seen = <String>[];
      await extractPdfImages(
        _fixture('enc_rc4_128.pdf'),
        fileName: 'secret.pdf',
        passwordProvider: (name) async {
          seen.add(name);
          return 'user123';
        },
      ).toList();
      expect(seen, isNotEmpty);
      expect(seen.every((n) => n == 'secret.pdf'), isTrue);
    });

    test('a provider stuck on a wrong password stops instead of spinning',
        () async {
      var calls = 0;
      await expectLater(
        extractPdfImages(
          _fixture('enc_aes128.pdf'),
          passwordProvider: (_) async {
            calls++;
            return 'never-right';
          },
        ).toList(),
        throwsA(isA<PdfEncryptedException>()),
      );
      expect(calls, lessThanOrEqualTo(kMaxPasswordAttempts));
      expect(calls, greaterThan(1));
    });

    test('PdfCancelledException is not an extraction failure', () {
      // The UI must be able to tell "user backed out" from "file is broken";
      // cancellation is normal control flow, not an error to toast.
      expect(const PdfCancelledException(), isNot(isA<PdfExtractException>()));
      expect(const PdfEncryptedException(), isA<PdfExtractException>());
    });
  });
}
