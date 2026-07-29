import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';

bool _isHandling = false;

/// Handle text share event.
/// [pageBuilder] creates the search page widget from the shared keyword.
/// The caller (in the UI layer) provides the builder to avoid a reverse
/// dependency on pages/.
void handleTextShare(Widget Function(String keyword) pageBuilder) async {
  if (_isHandling) return;
  _isHandling = true;

  var channel = EventChannel('venera/text_share');
  await for (var event in channel.receiveBroadcastStream()) {
    if (App.mainNavigatorKey == null) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (event is String) {
      if (!App.rootContext.mounted) continue;
      App.rootContext.to(() => pageBuilder(event));
    }
  }
}
