# Agent Instructions

## Build Commands

```bash
flutter pub get
flutter analyze
flutter test
```

## Architecture Constraints

- `lib/foundation/`, `lib/network/`, and `lib/utils/` **must not** import from `lib/pages/` or `lib/components/`.
  - Sole known exemption: `network/cloudflare.dart` → `pages/webview.dart` (tracked as #5, deferred due to missing Linux test environment).
  - This is the only dependency-direction rule that is enforced (see `test/architecture_test.dart`).
- Layering model: the UI layer (`pages` + `components`) depends on the non-UI layer (`foundation` + `network` + `utils`); the non-UI layer must never depend back on the UI layer. Within the non-UI layer there is **no** further linear ordering — `foundation`/`network` and `utils` intentionally import each other (e.g. `foundation/appdata.dart` uses `utils/`, while `utils/data_sync.dart` uses `foundation/`), so `utils` is a peer of `foundation`/`network`, not a lower tier.

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

All workflows that run `flutter pub get` set `PUB_HOSTED_URL: https://pub.flutter-io.cn` (workflow-level `env`), matching the mirror recorded in `pubspec.lock`. Without this, pub treats the lock's hosted entries as coming from a different source and silently re-resolves them, which has pulled in freshly released incompatible versions (jni 1.0.1, dio > 5.10.0). Keep local development and CI on the same pub source.

## Lint Rules

### `use_build_context_synchronously` (enabled)

This rule is globally enabled in `analysis_options.yaml` and **fully enforced across the codebase — there are no `// ignore_for_file: use_build_context_synchronously` exemptions left** (the 25 legacy exemptions were all cleared in 2026-07). New code must comply: guard every `BuildContext` use after an async gap with a `mounted` check.

Match the guard to the context being used, or the analyzer flags an "unrelated mounted check":
- A `State.context` use (context used directly inside a `State` method or a no-argument closure) → guard with `mounted`.
- A dialog/builder local `context` parameter → guard with `context.mounted`.
- `App.rootContext` → guard with `App.rootContext.mounted`.

When one async method has many downstream context uses, a single `if (!mounted) return;` right after the `await` covers them all.

## Visual Conventions

All existing code complies with these rules (converged in 2026-07); new UI code must not regress them.

- **Colors:** use `Theme.of(context).colorScheme` / `context.colorScheme` semantic colors. When text sits on a `*Container` background, use the paired `on*` color (e.g. `primaryContainer` → `onPrimaryContainer`) — never hard-coded `Colors.white`/`Colors.black`. Hard-coded colors are acceptable only for theme-independent overlays: barriers, shadows, and content drawn on top of images or fixed-color badges.
- **Corner radius:** use `AppRadius` tokens (`lib/components/consts.dart`): `xs`4 / `sm`8 / `md`12 / `lg`16 / `xl`24 / `full`. Pills, capsules and circular clips (avatars, pill buttons, track bars) must use `AppRadius.full` instead of a "half of the size" literal.
- **Spacing:** prefer `AppSpacing` tokens (4/8/12/16/24) for paddings, margins and gaps.
- **Font sizes:** stay on the scale 8/10/12/14/16/18/20/24 (helpers: `ts.sXX` in `foundation/widget_utils.dart`). Caption/secondary text is 12, body is 14–16, titles are 20 (both page Appbar and popup titles). Oversized display text (reader page numbers etc.) is exempt.

## Dependency Management

- All `git:` dependencies in `pubspec.yaml` **must** pin a `ref:` (commit SHA). Bare branch references are not allowed.
- `flutter_rust_bridge` runtime version must exactly match the codegen version used by the rhttp fork (currently `2.11.1`); see `dependency_overrides`.

## Release Process

Versions follow `major.minor.patch+build`, where the build number is the version without dots (e.g. `1.7.2+172`). Steps to cut a release:

1. **Bump both version sources together**: `pubspec.yaml` `version:` and `App.version` in `lib/foundation/app.dart` (a hard-coded constant read by the About page, update check, User-Agent, JS engine and PDF metadata). `test/version_consistency_test.dart` fails CI if they diverge, so run `flutter test` after bumping.
2. Push to `master`; then on GitHub create a release with tag `vX.Y.Z` targeting `master`. The `main.yml` (Build ALL) workflow triggers on `release: published` and builds every platform.
3. The release workflow uses `secrets.GITHUB_TOKEN` with `permissions: contents: write` to upload assets. After it finishes, verify the release has all platform assets (APK ×4 / IPA / Windows zip + installer exe / macOS dmg / Debian deb ×2 / Arch zst ×2).
4. `update_alt_store.yml` runs after Build ALL and commits the regenerated `alt_store.json` **directly to master** (no PR). Because it pushes to master, `git pull` locally before the next work session. The updater matches the IPA asset named `venera-D-ios-{version}+{build}.ipa`; if the release asset naming changes, update `update_alt_store.py` accordingly.

Notes: a release triggers workflows from the workflow files **at the tagged commit**, so any workflow fix must be committed (and the tag re-pointed) before it takes effect. This is a single-maintainer fork — direct pushes to `master` are the norm; there is no PR gate.
