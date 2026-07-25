import 'dart:math' as math;

/// Pure page calculation functions for the reader.
///
/// These functions encapsulate the core pagination logic used when displaying
/// comics with variable images-per-page settings and an optional "single image
/// on first page" mode.

/// Calculates the maximum page number given image count and layout settings.
///
/// When [singleImageOnFirstPage] is true, the first page shows exactly 1 image
/// and subsequent pages show [imagesPerPage] images each.
///
/// Returns 1 when [imageCount] is 0 or negative.
int calcMaxPage({
  required int imageCount,
  required int imagesPerPage,
  required bool singleImageOnFirstPage,
}) {
  if (imageCount <= 0) return 1;
  if (imagesPerPage <= 0) return 1;
  if (!singleImageOnFirstPage) {
    return (imageCount / imagesPerPage).ceil();
  } else {
    return 1 + ((imageCount - 1) / imagesPerPage).ceil();
  }
}

/// Returns the image index range `(startIndex, endIndex)` for a given 1-based
/// [page]. The range is half-open: images from `startIndex` (inclusive) to
/// `endIndex` (exclusive).
///
/// [totalImages] is needed to clamp the end index.
(int start, int end) getPageImagesRange({
  required int page,
  required int imagesPerPage,
  required int totalImages,
  required bool singleImageOnFirstPage,
}) {
  if (singleImageOnFirstPage) {
    if (page == 1) {
      return (0, math.min(1, totalImages));
    } else {
      int startIndex = (page - 2) * imagesPerPage + 1;
      int endIndex = math.min(startIndex + imagesPerPage, totalImages);
      return (startIndex, endIndex);
    }
  } else {
    int startIndex = (page - 1) * imagesPerPage;
    int endIndex = math.min(startIndex + imagesPerPage, totalImages);
    return (startIndex, endIndex);
  }
}

/// Converts a 1-based image index to the corresponding 1-based page number.
///
/// This is the inverse of [getPageImagesRange]: given an image index, returns
/// which page it would appear on.
int imageIndexToPage({
  required int imageIndex,
  required int imagesPerPage,
  required bool singleImageOnFirstPage,
}) {
  if (imageIndex <= 0) return 1;
  if (imagesPerPage <= 0) return 1;
  if (!singleImageOnFirstPage) {
    return ((imageIndex - 1) / imagesPerPage).floor() + 1;
  } else {
    if (imageIndex == 1) return 1;
    return ((imageIndex - 2) / imagesPerPage).floor() + 2;
  }
}

/// Adjusts the current page when the images-per-page value changes (e.g. on
/// screen rotation), preserving the reader's visual position.
///
/// Returns the new page number that shows approximately the same content.
int adjustPageForImagesPerPageChange({
  required int currentPage,
  required int oldImagesPerPage,
  required int newImagesPerPage,
  required bool singleImageOnFirstPage,
  required int totalImages,
}) {
  // Determine the first image index visible on the current page
  int previousImageIndex;
  if (!singleImageOnFirstPage || oldImagesPerPage == 1) {
    previousImageIndex = (currentPage - 1) * oldImagesPerPage + 1;
  } else {
    if (currentPage == 1) {
      previousImageIndex = 1;
    } else {
      previousImageIndex = (currentPage - 2) * oldImagesPerPage + 2;
    }
  }

  // Calculate the new page for that image index
  int newPage;
  if (newImagesPerPage != 1) {
    if (singleImageOnFirstPage) {
      newPage = ((previousImageIndex - 1) / newImagesPerPage).ceil() + 1;
    } else {
      newPage = (previousImageIndex / newImagesPerPage).ceil();
    }
  } else {
    newPage = previousImageIndex;
  }

  // Clamp to valid range
  int maxPage = calcMaxPage(
    imageCount: totalImages,
    imagesPerPage: newImagesPerPage,
    singleImageOnFirstPage: singleImageOnFirstPage,
  );
  return newPage.clamp(1, maxPage);
}
