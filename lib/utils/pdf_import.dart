import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf/images.dart';
import 'package:venera/utils/pdf/objects.dart';

/// Imports an image-based comic PDF, mirroring [CBZ.import]: extract every
/// page image into a cache directory, then run the shared registration tail.
///
/// JPEG pages are copied through untouched; Flate pages are re-encoded as PNG
/// (see utils/pdf/images.dart). Encrypted PDFs prompt via [passwordProvider].
abstract class PdfComic {
  static Future<LocalComic> import(
    File file, {
    PdfPasswordProvider? passwordProvider,
  }) async {
    final data = await file.readAsBytes();
    final cache = Directory(FilePath.join(App.cachePath, 'pdf_import'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync(recursive: true);
    final name = file.name;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    try {
      var index = 1;
      await for (final image in extractPdfImages(
        data,
        passwordProvider: passwordProvider,
        fileName: name,
      )) {
        final out =
            File(FilePath.join(cache.path, '$index.${image.extension}'));
        await out.writeAsBytes(image.bytes);
        index++;
      }
      return await CBZ.comicFromCacheDir(cache, title: title);
    } finally {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    }
  }
}
