import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/pdf_password_session.dart';
import 'package:venera/utils/translations.dart';

/// A folder of encrypted PDFs usually uses one password. The parser only calls
/// the provider again after a wrong password, so the session can hand out the
/// previous file's password without asking - and only the passwords that
/// actually opened something are worth handing out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> asked;
  late List<String?> answers;
  late List<String> messages;
  late PdfPasswordSession session;

  setUpAll(() async {
    appdata = Appdata.forTesting();
    App = createAppForTesting();
    await AppTranslation.init();
  });

  setUp(() {
    asked = [];
    answers = [];
    messages = [];
    session = PdfPasswordSession(
      ask: (fileName) async {
        asked.add(fileName);
        return answers.isEmpty ? null : answers.removeAt(0);
      },
      showMessage: messages.add,
    );
  });

  /// Hands [count] passwords to the provider and returns them, the way the
  /// parser does while it retries.
  Future<List<String?>> handOut(PdfPasswordProvider provider, int count) async {
    var issued = <String?>[];
    for (var i = 0; i < count; i++) {
      issued.add(await provider('comic.pdf'));
    }
    return issued;
  }

  /// Opens one file whose password the user types, so it is remembered. The
  /// provider may hand out remembered passwords first; those are drained until
  /// the typed one comes back.
  Future<void> openWithTypedPassword(String password) async {
    answers.add(password);
    var provider = session.providerFor();
    var issuances = 0;
    while (await provider('comic.pdf') != password) {
      if (++issuances > kMaxRememberedPdfPasswords + 2) {
        fail('the typed password never came back from the provider');
      }
    }
    session.rememberLastIssued();
    // A remembered password can already be the one being typed, in which case
    // the queue entry was never consumed; leaving it there would feed the next
    // phase a password the test did not plan for.
    answers.clear();
  }

  test('asks without a toast when nothing is remembered', () async {
    answers.add('right');
    var provider = session.providerFor();

    expect(await provider('comic.pdf'), 'right');
    expect(asked, ['comic.pdf']);
    expect(messages, isEmpty,
        reason: 'the first prompt follows the silent empty-password attempt');
  });

  test('reuses the password that opened the previous file', () async {
    await openWithTypedPassword('shared');

    var provider = session.providerFor();
    expect(await provider('next.pdf'), 'shared');
    expect(asked, ['comic.pdf'],
        reason: 'the second file must not reach the prompt at all');
    expect(messages, isEmpty);
  });

  test('a remembered password that fails falls through to the prompt',
      () async {
    await openWithTypedPassword('old');
    answers.add('new');

    var provider = session.providerFor();
    expect(await handOut(provider, 2), ['old', 'new']);
    expect(messages, isEmpty,
        reason: 'the silent probe is not the user typing a wrong password');
  });

  test('a wrong typed password toasts before asking again', () async {
    answers.addAll(['wrong', 'right']);
    var provider = session.providerFor();

    expect(await handOut(provider, 3), ['wrong', 'right', null]);
    expect(asked.length, 3);
    expect(messages, ["Incorrect password".tl, "Incorrect password".tl],
        reason: 'the toast reports the password the user typed, and the last '
            'call is the prompt for the third attempt');
  });

  test('a cancelled prompt resolves to null and is not remembered', () async {
    var provider = session.providerFor();
    expect(await provider('comic.pdf'), isNull);

    session.rememberLastIssued();

    var next = session.providerFor();
    answers.add('typed');
    expect(await next('next.pdf'), 'typed');
    expect(asked, ['comic.pdf', 'next.pdf'],
        reason: 'cancelling must not put anything into the session');
  });

  test('probes most recent first, without duplicates', () async {
    for (var password in ['a', 'b', 'a']) {
      await openWithTypedPassword(password);
    }

    var promptsBefore = asked.length;
    var provider = session.providerFor();
    expect(await handOut(provider, 3), ['a', 'b', null]);
    expect(asked.length - promptsBefore, 1,
        reason: 'two remembered passwords, then one prompt');
  });

  test('remembers at most as many passwords as the attempt budget allows',
      () async {
    for (var password in ['p1', 'p2', 'p3', 'p4', 'p5', 'p6']) {
      await openWithTypedPassword(password);
    }

    var provider = session.providerFor();
    answers.add('typed');
    expect(await handOut(provider, kMaxRememberedPdfPasswords + 1),
        ['p6', 'p5', 'p4', 'p3', 'p2', 'typed'],
        reason: 'the oldest password is dropped so the prompt still fits in '
            'the parser\'s attempt budget');
    expect(kMaxRememberedPdfPasswords, lessThanOrEqualTo(5));
  });

  test('a file that needed no password remembers nothing', () async {
    session.rememberLastIssued();

    var provider = session.providerFor();
    answers.add('typed');
    expect(await provider('next.pdf'), 'typed',
        reason: 'no provider call means no password was handed out');
    expect(asked, ['next.pdf']);
  });

  test('an empty password is never remembered', () async {
    await openWithTypedPassword('');

    var provider = session.providerFor();
    answers.add('typed');
    expect(await provider('next.pdf'), 'typed',
        reason: 'the parser tries the empty password on its own for every '
            'file, so probing it again only wastes an attempt');
  });
}
