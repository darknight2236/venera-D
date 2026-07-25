import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/page_math.dart';

void main() {
  group('calcMaxPage', () {
    test('returns 1 for zero images', () {
      expect(
        calcMaxPage(imageCount: 0, imagesPerPage: 2, singleImageOnFirstPage: false),
        1,
      );
    });

    test('returns 1 for negative image count', () {
      expect(
        calcMaxPage(imageCount: -5, imagesPerPage: 2, singleImageOnFirstPage: false),
        1,
      );
    });

    test('basic pagination without single first page', () {
      // 10 images, 2 per page => 5 pages
      expect(
        calcMaxPage(imageCount: 10, imagesPerPage: 2, singleImageOnFirstPage: false),
        5,
      );
    });

    test('rounds up when images do not evenly divide', () {
      // 11 images, 2 per page => 6 pages
      expect(
        calcMaxPage(imageCount: 11, imagesPerPage: 2, singleImageOnFirstPage: false),
        6,
      );
    });

    test('single image per page equals image count', () {
      expect(
        calcMaxPage(imageCount: 7, imagesPerPage: 1, singleImageOnFirstPage: false),
        7,
      );
    });

    test('with singleImageOnFirstPage: first page has 1, rest use imagesPerPage', () {
      // 10 images, 2 per page, first page single:
      // page 1: 1 image, remaining 9 images / 2 per page = 5 pages => total 6
      expect(
        calcMaxPage(imageCount: 10, imagesPerPage: 2, singleImageOnFirstPage: true),
        6,
      );
    });

    test('singleImageOnFirstPage with 1 image returns 1 page', () {
      expect(
        calcMaxPage(imageCount: 1, imagesPerPage: 2, singleImageOnFirstPage: true),
        1,
      );
    });

    test('singleImageOnFirstPage with exact fit after first page', () {
      // 5 images, 2 per page, first page single:
      // page 1: 1 image, remaining 4 / 2 = 2 pages => total 3
      expect(
        calcMaxPage(imageCount: 5, imagesPerPage: 2, singleImageOnFirstPage: true),
        3,
      );
    });

    test('singleImageOnFirstPage with remainder after first page', () {
      // 6 images, 4 per page, first page single:
      // page 1: 1 image, remaining 5 / 4 = ceil(1.25) = 2 pages => total 3
      expect(
        calcMaxPage(imageCount: 6, imagesPerPage: 4, singleImageOnFirstPage: true),
        3,
      );
    });
  });

  group('getPageImagesRange', () {
    test('first page without singleImageOnFirstPage', () {
      var (start, end) = getPageImagesRange(
        page: 1, imagesPerPage: 2, totalImages: 10, singleImageOnFirstPage: false,
      );
      expect(start, 0);
      expect(end, 2);
    });

    test('second page without singleImageOnFirstPage', () {
      var (start, end) = getPageImagesRange(
        page: 2, imagesPerPage: 2, totalImages: 10, singleImageOnFirstPage: false,
      );
      expect(start, 2);
      expect(end, 4);
    });

    test('last page clamps to totalImages', () {
      // 11 images, 2 per page, page 6: start=10, end=min(12,11)=11
      var (start, end) = getPageImagesRange(
        page: 6, imagesPerPage: 2, totalImages: 11, singleImageOnFirstPage: false,
      );
      expect(start, 10);
      expect(end, 11);
    });

    test('first page with singleImageOnFirstPage shows only 1 image', () {
      var (start, end) = getPageImagesRange(
        page: 1, imagesPerPage: 3, totalImages: 10, singleImageOnFirstPage: true,
      );
      expect(start, 0);
      expect(end, 1);
    });

    test('second page with singleImageOnFirstPage starts at index 1', () {
      var (start, end) = getPageImagesRange(
        page: 2, imagesPerPage: 3, totalImages: 10, singleImageOnFirstPage: true,
      );
      expect(start, 1);
      expect(end, 4);
    });

    test('third page with singleImageOnFirstPage', () {
      var (start, end) = getPageImagesRange(
        page: 3, imagesPerPage: 3, totalImages: 10, singleImageOnFirstPage: true,
      );
      expect(start, 4);
      expect(end, 7);
    });
  });

  group('imageIndexToPage', () {
    test('first image is on page 1', () {
      expect(
        imageIndexToPage(imageIndex: 1, imagesPerPage: 2, singleImageOnFirstPage: false),
        1,
      );
    });

    test('image at boundary goes to next page', () {
      // 2 per page: image 3 is on page 2
      expect(
        imageIndexToPage(imageIndex: 3, imagesPerPage: 2, singleImageOnFirstPage: false),
        2,
      );
    });

    test('last image on page stays on that page', () {
      // 2 per page: image 4 is on page 2
      expect(
        imageIndexToPage(imageIndex: 4, imagesPerPage: 2, singleImageOnFirstPage: false),
        2,
      );
    });

    test('with singleImageOnFirstPage, image 1 is on page 1', () {
      expect(
        imageIndexToPage(imageIndex: 1, imagesPerPage: 3, singleImageOnFirstPage: true),
        1,
      );
    });

    test('with singleImageOnFirstPage, image 2 is on page 2', () {
      expect(
        imageIndexToPage(imageIndex: 2, imagesPerPage: 3, singleImageOnFirstPage: true),
        2,
      );
    });

    test('with singleImageOnFirstPage, image 4 is on page 2', () {
      // page 1: image 1; page 2: images 2-4
      expect(
        imageIndexToPage(imageIndex: 4, imagesPerPage: 3, singleImageOnFirstPage: true),
        2,
      );
    });

    test('with singleImageOnFirstPage, image 5 is on page 3', () {
      // page 1: image 1; page 2: images 2-4; page 3: images 5-7
      expect(
        imageIndexToPage(imageIndex: 5, imagesPerPage: 3, singleImageOnFirstPage: true),
        3,
      );
    });

    test('zero or negative index returns 1', () {
      expect(imageIndexToPage(imageIndex: 0, imagesPerPage: 2, singleImageOnFirstPage: false), 1);
      expect(imageIndexToPage(imageIndex: -1, imagesPerPage: 2, singleImageOnFirstPage: false), 1);
    });
  });

  group('adjustPageForImagesPerPageChange', () {
    test('going from 1 to 2 images per page halves the page count', () {
      // On page 5 with 1 image/page => image index 5
      // With 2 images/page => page ceil(5/2) = 3
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 5,
          oldImagesPerPage: 1,
          newImagesPerPage: 2,
          singleImageOnFirstPage: false,
          totalImages: 10,
        ),
        3,
      );
    });

    test('going from 2 to 1 image per page doubles position', () {
      // On page 3 with 2 images/page => first image index = (3-1)*2+1 = 5
      // With 1 image/page => page = 5
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 3,
          oldImagesPerPage: 2,
          newImagesPerPage: 1,
          singleImageOnFirstPage: false,
          totalImages: 10,
        ),
        5,
      );
    });

    test('page 1 stays page 1 when singleImageOnFirstPage', () {
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 1,
          oldImagesPerPage: 2,
          newImagesPerPage: 3,
          singleImageOnFirstPage: true,
          totalImages: 10,
        ),
        1,
      );
    });

    test('with singleImageOnFirstPage, preserves visual position', () {
      // On page 2 with old=2 per page, singleFirst=true
      // First image index = (2-2)*2+2 = 2
      // New imagesPerPage=4, singleFirst=true:
      // newPage = ceil((2-1)/4)+1 = ceil(0.25)+1 = 1+1 = 2
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 2,
          oldImagesPerPage: 2,
          newImagesPerPage: 4,
          singleImageOnFirstPage: true,
          totalImages: 20,
        ),
        2,
      );
    });

    test('clamps to maxPage when result would exceed', () {
      // 5 images, on page 5 with 1/page, switching to 3/page
      // maxPage = ceil(5/3) = 2, so clamped to 2
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 5,
          oldImagesPerPage: 1,
          newImagesPerPage: 3,
          singleImageOnFirstPage: false,
          totalImages: 5,
        ),
        2,
      );
    });

    test('same imagesPerPage returns same page', () {
      expect(
        adjustPageForImagesPerPageChange(
          currentPage: 3,
          oldImagesPerPage: 2,
          newImagesPerPage: 2,
          singleImageOnFirstPage: false,
          totalImages: 10,
        ),
        3,
      );
    });
  });

  group('round-trip consistency', () {
    test('getPageImagesRange first image matches imageIndexToPage', () {
      for (int page = 1; page <= 5; page++) {
        var (start, _) = getPageImagesRange(
          page: page, imagesPerPage: 2, totalImages: 10, singleImageOnFirstPage: false,
        );
        // start is 0-based, imageIndexToPage expects 1-based
        int computedPage = imageIndexToPage(
          imageIndex: start + 1, imagesPerPage: 2, singleImageOnFirstPage: false,
        );
        expect(computedPage, page, reason: 'Round-trip failed for page $page');
      }
    });

    test('getPageImagesRange with singleFirst matches imageIndexToPage', () {
      for (int page = 1; page <= 4; page++) {
        var (start, _) = getPageImagesRange(
          page: page, imagesPerPage: 3, totalImages: 12, singleImageOnFirstPage: true,
        );
        int computedPage = imageIndexToPage(
          imageIndex: start + 1, imagesPerPage: 3, singleImageOnFirstPage: true,
        );
        expect(computedPage, page, reason: 'Round-trip failed for page $page');
      }
    });
  });
}
