<p align="center">
  <img src="assets/app_icon.png" width="120" alt="Venera-D app icon"/>
</p>

# venera-D

**English** · [简体中文](README_zh.md)

[![flutter](https://img.shields.io/badge/flutter-3.47.6-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/darknight2236/venera-D)](https://github.com/darknight2236/venera-D/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/darknight2236/venera-D?style=flat)](https://github.com/darknight2236/venera-D/stargazers)

A cross-platform comic reader that supports reading local and network comics.

> **About this fork**
> `venera-D` is a fork of [venera](https://github.com/venera-app/venera), which is no longer maintained and has
> since been **archived** upstream (the repository has been read-only since April 2026), so nothing new will
> arrive from there.
> This fork keeps all original features, maintains **code health** (reducing coupling, adding test seams, and
> making the settings layer type-safe — see [Architecture & Decoupling](#architecture--decoupling)), and is
> actively adding **new features** on top of the upstream app (see [What's new](#whats-new-in-venera-d)).

## Features

- Read local comics — imported from directories, archive files (`cbz` / `zip` / `7z` / `cb7`) or image-based PDFs
- Use JavaScript to create and load network comic sources
- Read comics from network sources
- Manage favorite comics (local and network folders)
- Download comics for offline reading
- View comments, tags, ratings, and other metadata if the source supports it
- Log in to comment, rate, and perform other interactions if the source supports it
- Headless mode for GUI-less / server usage

## What's new in venera-D

Features added on top of the upstream app:

**Reading experience**

- Gallery mode downsamples large images for smoother paging (toggleable in reader settings)
- Tap the top/bottom half to turn pages in left-right reading modes
- Fixed tap-to-turn scroll distance in continuous mode (for strip comics)
- Optional white-screen flash on page turn to reduce ghosting on e-ink devices
- Reading progress badge on the home history thumbnails (page count of the current chapter, check mark once
  finished), matching the history page
- Favorite state shown on list thumbnails, with a distinct marker for network favorites
- Current page title stays visible in the folded sidebar on wide screens and phones held sideways

**Import & formats**

- Image-based PDF comic import — one comic per file, JPEG pages copied through byte-for-byte and
  Flate-compressed pages converted to PNG. Image pages only: text or vector pages are rejected with a
  clear message rather than imported as a broken comic.
- Password-protected PDFs are supported (standard security handler, revisions R2–R6: RC4-40/128, AES-128,
  AES-256); files whose user password is empty open without prompting.
- Case-insensitive image extension checks, shared by directory scanning, cover lookup and archive import

**Management & convenience**

- Search within reading history
- Sort local favorites by favorite time or manually
- Copy just part of a title from the long-press menu
- Convert comic titles to simplified Chinese for display

**Stability**

- Download pipeline: request timeouts, per-image failure tolerance, task de-duplication, and skipping
  already-downloaded chapters on re-download
- Simplified/Traditional Chinese normalized in favorites search

## Supported Platforms

Android · iOS · Windows · Linux · macOS

## Download

Every [release](https://github.com/darknight2236/venera-D/releases/latest) attaches prebuilt binaries for all
supported platforms: Android (a universal APK plus `arm64-v8a` / `armeabi-v7a` / `x86_64`), Windows (`.zip`
and an installer `.exe`), macOS (`.dmg`), Linux (Debian `.deb` and Arch `.pkg.tar.zst`, amd64 and arm64) and
iOS (`.ipa`).

On iOS the build is additionally published as an **AltStore source**, so it can be installed and updated
without a computer-side rebuild: add the URL below as a source in AltStore, then install **Venera-D**.

```
https://raw.githubusercontent.com/darknight2236/venera-D/master/alt_store.json
```

That file is regenerated automatically right after each release, so it always points at the newest build.

## Build from Source

1. Clone the repository.
2. Install Flutter — see [flutter.dev](https://flutter.dev/docs/get-started/install) (Flutter `3.47.6`, Dart SDK `>=3.8.0`).
3. Install Rust — see [rustup.rs](https://rustup.rs/).
4. Install JDK 17 or newer if you intend to build for Android.
5. Make sure `flutter pub get` can reach the patched fork dependencies. Three of them are pinned over SSH
   (`ssh://git@ssh.github.com:443/…`) because the maintainer's network has unstable HTTPS access to
   github.com. They are **public** repositories, so if SSH on port 443 is not available to you, rewrite
   those URLs to HTTPS once and pub will fetch them anonymously:

   ```bash
   git config --global url."https://github.com/".insteadOf "ssh://git@ssh.github.com:443/"
   ```

6. Build for your platform, for example:
   - Android: `flutter build apk`
   - Windows: `flutter build windows --release`
   - Linux: `flutter build linux --release`
   - macOS: `flutter build macos --release`
   - iOS: `flutter build ipa`

## Documentation

- [Create a Comic Source](doc/comic_source.md) — how to write a JavaScript comic source
- [JS API Reference](doc/js_api.md) — the JavaScript bridge API available to sources
- [Import Comic](doc/import_comic.md) — importing local comic files, including the supported and unsupported
  PDF page/image encodings
- [Headless Mode](doc/headless_doc.md) — running without a GUI

## Architecture & Decoupling

This fork carries out an incremental, low-risk refactoring effort aimed at long-term maintainability
(the project is a single-maintainer fork, so the goal is "fix what bites", not architectural purity):

- **Layer inversion removed** — `foundation`/`network` no longer reverse-import the UI layer, restoring
  independent compilation and unlocking `headless` mode and tests.
- **Test seams** — the `Appdata` and `App` global singletons expose test-only constructors/setters,
  enabling unit tests without I/O side effects.
- **Type-safe settings** — every settings key is now a compile-time constant (`SettingKeys`), so a
  misspelled key is a build error instead of a silent runtime failure.

Details and the full status: [Coupling Analysis Report](doc/venera-D-coupling-analysis.md) and the
[Layer Inversion Refactor Plan](doc/layer-inversion-refactor-plan.md).

## Thanks

### Tags Translation

The Chinese translation of the comic tags is from [EhTagTranslation](https://github.com/EhTagTranslation/Database).
