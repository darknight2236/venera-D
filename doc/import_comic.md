# Import Comic

## Introduction

Venera supports importing comics from local files.
However, the comic files must be in a specific format.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a supported image
extension: `.jpg`, `.jpeg`, `.jpe`, `.png`, `.webp`, `.gif`, `.avif`, `.bmp`
(case-insensitive). The same list is used when reading chapters, importing and
exporting cbz.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

Venera supports importing comics from archive files.

The archive file must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, Venera supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

## PDF

Venera supports importing **image-based comic PDFs** — PDFs whose pages are
scanned or illustrated images, one image per page. Each imported PDF becomes a
single chapterless comic, mirroring the archive import behaviour.

- Open `Local` -> `Import` -> `A PDF file` (a single PDF) or
  `Multiple PDF files` (a directory containing PDFs).
- The comic title is the file name without its extension. PDF `/Title` metadata
  is deliberately not used, so files exported by tools that leave it blank do
  not arrive titled "Untitled".
- JPEG pages are copied through byte-for-byte (lossless, no re-encoding);
  Flate-compressed pages are converted to PNG.

### Encryption

Password-protected PDFs are supported (standard security handler, revisions
R2-R6: RC4-40/128, AES-128 and AES-256).

- Files encrypted with an **empty user password** (owner password only) open
  silently, without prompting.
- Otherwise a password dialog appears, named after the file it is asking for.
  A wrong password shows "Incorrect password" and asks again; cancelling aborts
  that file.
- In a batch import, cancelling skips only the current file and the remaining
  PDFs still import.

### Supported image formats

DeviceRGB, DeviceGray and DeviceCMYK (including Adobe-inverted CMYK), plus the
indirect forms `/ICCBased` (mapped by component count) and `/Indexed` (palette
expanded). 8-bit and 16-bit samples are supported, 16-bit being downsampled to
8. Predictor-encoded Flate streams (both PNG and TIFF predictors) are handled.

### Not supported

- **Vector or text-only pages.** A PDF containing no page images reports
  "No images found in the PDF".
- **Inline images** (`BI`/`ID`/`EI`) inside content streams.
- **`JPXDecode`, `CCITTFaxDecode` and `JBIG2Decode`** image encodings. The error
  message names the page number and the encoding. Convert such a PDF to `.cbz`
  with an external tool and import that instead.
- Chapter structure inside the PDF, and the `metadata.json` mechanism used by
  archives.
