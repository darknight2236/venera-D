# venera-D

**English** · [简体中文](README_zh.md)

[![flutter](https://img.shields.io/badge/flutter-3.44.6-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/darknight2236/venera-D)](https://github.com/darknight2236/venera-D/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/darknight2236/venera-D?style=flat)](https://github.com/darknight2236/venera-D/stargazers)

A cross-platform comic reader that supports reading local and network comics.

> **About this fork**
> `venera-D` is a fork of [venera](https://github.com/venera-app/venera), which is no longer maintained upstream.
> This fork keeps all original features while focusing on **code health**: reducing coupling, adding test
> seams, and making the settings layer type-safe. See [Architecture & Decoupling](#architecture--decoupling).

## Features

- Read local comics
- Use JavaScript to create and load network comic sources
- Read comics from network sources
- Manage favorite comics (local and network folders)
- Download comics for offline reading
- View comments, tags, ratings, and other metadata if the source supports it
- Log in to comment, rate, and perform other interactions if the source supports it
- Headless mode for GUI-less / server usage

## Supported Platforms

Android · iOS · Windows · Linux · macOS

## Build from Source

1. Clone the repository.
2. Install Flutter — see [flutter.dev](https://flutter.dev/docs/get-started/install) (Flutter `3.44.6`, Dart SDK `>=3.8.0`).
3. Install Rust — see [rustup.rs](https://rustup.rs/).
4. Build for your platform, for example:
   - Android: `flutter build apk`
   - Windows: `flutter build windows --release`
   - Linux: `flutter build linux --release`
   - macOS: `flutter build macos --release`
   - iOS: `flutter build ipa`

## Documentation

- [Create a Comic Source](doc/comic_source.md) — how to write a JavaScript comic source
- [JS API Reference](doc/js_api.md) — the JavaScript bridge API available to sources
- [Import Comic](doc/import_comic.md) — importing local comic files
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
