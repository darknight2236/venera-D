import 'package:flutter/widgets.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/search_result_page.dart';

/// UI-layer navigation for [PageJumpTarget].
///
/// Implemented as an extension so that foundation/comic_source no longer needs
/// to import the search/category pages. Call sites must import this file to
/// bring [jump] into scope.
extension PageJumpTargetExt on PageJumpTarget {
  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: List.from(attributes?["options"] ?? []),
        )
      );
    } else if (page == "category") {
      var key = ComicSource.find(sourceKey)!.categoryData!.key;
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category: attributes?["category"] ??
              (throw ArgumentError("Category name is required")),
          options: List.from(attributes?["options"] ?? []),
          param: attributes?["param"],
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
