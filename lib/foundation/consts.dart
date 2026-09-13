/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Default user agent for http requests.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;

/// Image file extensions the app can import, render and export (lowercase).
///
/// Single source of truth shared by the local-comic reader scan, import
/// validation, cbz handling and cover lookup. These lists drifted apart over
/// time (e.g. .jpe counted on import but skipped while reading, .avif/.bmp
/// readable but rejected on import, and most checks were case-sensitive so
/// files like IMG.JPG were missed).
const supportedImageExtensions = [
  'jpg', 'jpeg', 'jpe', 'png', 'webp', 'gif', 'avif', 'bmp',
];

/// Whether [name] (a file name or path) ends with a supported image
/// extension. Case-insensitive; returns false when there is no extension.
bool isSupportedImageName(String name) {
  var dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return supportedImageExtensions
      .contains(name.substring(dot + 1).toLowerCase());
}