# Agent guide

Wavebook is local-library Swift macOS app (minimum macOS 15). Source, tests, `project.yml`, and workflows are authoritative; verify behavior rather than infer features.

## Map

- `Wavebook/App/` — UI and coordination.
- `Wavebook/Sources/WavebookCore/` — playback, library, database, lyrics, and analysis.
- `Wavebook/Tests/WavebookCoreTests/` — core tests.
- `project.yml` — canonical XcodeGen spec; `Wavebook.xcodeproj/` is generated.
- `.github/workflows/`, `scripts/` — CI, release, and validation.

## Checks

Run at repo root:

```sh
just ci       # runner-parity checks (Xcode 16.4 / Swift 6.1.2)
just test     # WavebookTests scheme
just lint
just check-pbx
```

Recipes need `just` (https://github.com/casey/just), and SwiftLint as applicable. Run smallest relevant check, broader checks when practical, and report actual commands/results. See `.github/workflows/ci.yml` for CI checks.

For parity with the current GitHub Actions toolchain, run:

```sh
WAVEBOOK_DEVELOPER_DIR="/Applications/Xcode16.4.app/Contents/Developer" just ci
```

`WAVEBOOK_DEVELOPER_DIR` must point to Xcode's `Contents/Developer` directory. `just ci` checks exact Xcode/Swift versions, regenerates and verifies the project, validates repository tooling, runs tests, and builds Release. `just test` saves an `.xcresult` under `.build`; export crash attachments with `xcrun xcresulttool export attachments --path <bundle> --output-path .build/test-attachments --only-failures`. Update the version check when CI's toolchain changes. `project.yml`'s `xcodeVersion` controls generated project metadata; it does not select the compiler.

For project changes, edit `project.yml`, run `xcodegen generate --spec project.yml`, and review generated diff; never hand-edit `Wavebook.xcodeproj`. Keep context-specific SwiftPM lockfile pins aligned; use `scripts/check-package-locks.py`.

Xcode 16.4 can be downloaded at https://developer.apple.com/download/all.

## Change rules

- Inspect relevant code, callers, and tests; preserve patterns and limit scope. Add/update tests for behavior changes.
- Unless user asks, always AppKit.
- Framework callbacks can run off-actor even when registered from actor-isolated code. Mark callback boundaries `@Sendable` where appropriate, then hop to the owning actor before accessing actor-isolated state; verify with the CI toolchain.
- For persistence changes, inspect schema/migrations and test migration and failure paths.
- Preserve data boundaries: selected-folder reads, unsandboxed direct-download build, track metadata sent to LRCLIB, and downloaded `.lrc` files beside audio. Update `PRIVACY.md` when access or network behavior changes.
- Update `FEATURES.md`/`README.md` for user-facing changes, `CONTRIBUTING.md` for workflow changes, release/dependency docs when those facts change and `CHANGELOG.md` when done with changes.
- Check `LICENSE` before reuse/distribution claims: project code is Apache 2.0 with Commons Clause v1.0; dependencies have separate terms.

See [README.md](README.md), [FEATURES.md](FEATURES.md), [PRIVACY.md](PRIVACY.md), and [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidance.
