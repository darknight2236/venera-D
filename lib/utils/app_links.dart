import 'package:flutter/widgets.dart';
import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void handleLinks(Widget Function(String id, String sourceKey) pageBuilder) {
  final appLinks = AppLinks();
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri, pageBuilder);
  });
}

Future<bool> handleAppLink(Uri uri,
    [Widget Function(String id, String sourceKey)? pageBuilder]) async {
  for(var source in ComicSource.all()) {
    if(source.linkHandler != null) {
      if(source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if(id != null) {
          if(App.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          if (pageBuilder != null) {
            App.mainNavigatorKey!.currentContext?.to(() {
              return pageBuilder(id, source.key);
            });
            return true;
          }
          return false;
        }
        return false;
      }
    }
  }
  return false;
}