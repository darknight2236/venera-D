import 'package:venera/utils/pdf/objects.dart';
import 'package:venera/utils/translations.dart';

/// How many passwords one import operation remembers.
///
/// The parser re-asks the provider at most `kMaxPasswordAttempts` (7) times per
/// file, and every remembered password it hands out consumes one of those
/// attempts. Five leaves the user the two prompts the single-file flow always
/// had: the first one, and the retry after "Incorrect password".
const int kMaxRememberedPdfPasswords = 5;

/// Remembers the passwords that actually opened a file during one import
/// operation, so the rest of the batch is tried against them before it asks
/// again.
///
/// Nothing is written to disk: the list lives as long as the operation does.
class PdfPasswordSession {
  PdfPasswordSession({required this.ask, required this.showMessage});

  /// The UI prompt, called only once every remembered password has failed.
  final PdfPasswordProvider ask;

  final void Function(String message) showMessage;

  /// Most recently successful first.
  final List<String> _known = [];

  /// The password handed out for the file currently being opened, and whether
  /// the user typed it.
  String? _issued;
  bool _issuedFromUser = false;

  /// A provider for one file.
  ///
  /// It hands out [_known] in order without any UI - a silent probe must not
  /// report "Incorrect password" for something the user never typed - then
  /// falls through to [ask]. A null return means the user cancelled, which the
  /// parser reads as "skip this file".
  PdfPasswordProvider providerFor() {
    var probes = 0;
    _issued = null;
    _issuedFromUser = false;
    return (fileName) async {
      if (_issuedFromUser) showMessage("Incorrect password".tl);
      if (probes < _known.length) {
        _issued = _known[probes++];
        _issuedFromUser = false;
        return _issued;
      }
      var typed = await ask(fileName);
      _issued = typed;
      _issuedFromUser = typed != null;
      return typed;
    };
  }

  /// Call once a file finished importing and its password, if it needed one,
  /// was accepted: either the import succeeded, or it failed for a reason
  /// other than the password.
  ///
  /// The parser only asks again after a failed password, so the last password
  /// handed out for that file is the one that worked.
  void rememberLastIssued() {
    var issued = _issued;
    // An empty password never reaches here through the parser (it tries that
    // itself before asking), and remembering one would only spend an attempt
    // on every later file.
    if (issued == null || issued.isEmpty) return;
    _known.remove(issued);
    _known.insert(0, issued);
    if (_known.length > kMaxRememberedPdfPasswords) {
      _known.removeRange(kMaxRememberedPdfPasswords, _known.length);
    }
  }
}
