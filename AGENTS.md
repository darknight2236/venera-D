# Agent Instructions

## Build Commands

```bash
flutter pub get
flutter analyze
flutter test
```

## Architecture Constraints

- `lib/foundation/` and `lib/network/` **must not** import from `lib/pages/` or `lib/components/`.
  - Sole known exemption: `network/cloudflare.dart` → `pages/webview.dart` (tracked as #5, deferred due to missing Linux test environment).
- Dependency direction: `pages/components` → `foundation/network` → `utils`. Never reverse.

## Testing Requirements

- Changes to `lib/foundation/` must include or update corresponding tests in `test/`.
- Global singletons (`Appdata`, `App`) expose test-only constructors (`forTesting()`, `createAppForTesting()`); use them instead of mocking the real init path.

## Environment Setup

`pubspec.yaml` references three patched fork dependencies via SSH URLs (`ssh://git@ssh.github.com:443/darknight2236/...`):

| Fork | Patch reason |
|------|------|
| `rhttp` | compileSdk 36 + cargokit Gradle 9 exec fix |
| `zip_flutter` | compileSdk 36 |
| `flutter_inappwebview` | proguard-android-optimize fix |

These forks are **public** repositories. SSH URLs are used because the maintainer's local network has unstable HTTPS access to github.com.

### Local setup (choose one)

1. **SSH key (recommended):** Ensure `ssh -T git@ssh.github.com -p 443` succeeds. No extra config needed.
2. **HTTPS fallback:** If SSH is unavailable, run once:
   ```bash
   git config --global url."https://github.com/".insteadOf "ssh://git@ssh.github.com:443/"
   ```
   This transparently rewrites SSH URLs to HTTPS for `flutter pub get`.

### CI configuration

GitHub Actions runners have no SSH key and HTTPS works normally. Each build job runs the same `git config insteadOf` rewrite (see workflow files) to clone the public forks via HTTPS anonymously.

## Lint Rules

### `use_build_context_synchronously` (enabled)

This rule is globally enabled in `analysis_options.yaml`. **New code must comply** — add a `mounted` check before using `BuildContext` after an async gap.

The following 25 files have a legacy `// ignore_for_file: use_build_context_synchronously` exemption (pre-existing violations, to be fixed incrementally):

| Area | Files |
|------|-------|
| components | `message.dart`, `rich_comment_content.dart`, `window_frame.dart` |
| pages/comic_details_page | `actions.dart`, `comic_page.dart`, `comments_page.dart`, `favorite.dart` |
| pages/favorites | `favorite_actions.dart`, `network_favorites_page.dart` |
| pages/reader | `chapter_comments.dart`, `gesture.dart`, `images.dart`, `reader.dart`, `scaffold.dart` |
| pages/settings | `about.dart`, `app.dart`, `local_favorites.dart` |
| pages (root) | `comic_source_page.dart`, `history_page.dart`, `home_page.dart`, `local_comics_page.dart` |
| utils | `data_sync.dart`, `handle_text_share.dart`, `import_comic.dart`, `io.dart` |

When touching these files, prefer removing the file-level ignore and adding per-site `mounted` guards instead.

## Dependency Management

- All `git:` dependencies in `pubspec.yaml` **must** pin a `ref:` (commit SHA). Bare branch references are not allowed.
- `flutter_rust_bridge` runtime version must exactly match the codegen version used by the rhttp fork (currently `2.11.1`); see `dependency_overrides`.
