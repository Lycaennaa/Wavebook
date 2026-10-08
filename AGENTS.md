# Agent guide

Wavebook is local-library Swift macOS app (minimum macOS 15). Source, tests, `project.yml`, and workflows are authoritative; verify behavior rather than infer features.

## Map

- `Wavebook/App/` — UI and coordination.
- `Wavebook/Sources/WavebookCore/` — playback, library, database, lyrics, and analysis.
- `Wavebook/Tests/WavebookCoreTests/` — core tests.
- `project.yml` — canonical XcodeGen spec; `Wavebook.xcodeproj/` is generated.
- `.github/workflows/`, `scripts/` — CI, release, and validation.

## Checks

See [DEVELOPMENT.md](DEVELOPMENT.md) for prerequisites, repository commands, toolchain pins, and test-result diagnostics. `just ci` is the strict local parity check; its pinned toolchain differs from GitHub CI's minimum-version policy. Run the smallest relevant check first, broader checks when practical, and report actual commands and results. See [the CI workflow](.github/workflows/ci.yml) for hosted checks.


## Change rules

- Inspect relevant code, callers, and tests; preserve patterns and limit scope. Add/update tests for behavior changes.
- Unless user asks, always AppKit.
- Framework callbacks can run off-actor even when registered from actor-isolated code. Mark callback boundaries `@Sendable` where appropriate, then hop to the owning actor before accessing actor-isolated state; verify with the CI toolchain.
- For persistence changes, inspect schema/migrations and test migration and failure paths.
- Preserve data boundaries: selected-folder reads, unsandboxed direct-download build, track metadata sent to LRCLIB, and downloaded `.lrc` files beside audio. Update `PRIVACY.md` when access or network behavior changes.
- Update user-facing docs (`README.md`, `FEATURES.md`, `INSTALLATION.md`, `PRIVACY.md`) when behavior or data access changes; update `SETUP.md`/`DEVELOPMENT.md` for developer workflow, `ARCHITECTURE.md` for structural changes, `CONTRIBUTING.md` for contribution workflow, and `CHANGELOG.md` for user-visible changes.
- Check `LICENSE` before reuse/distribution claims: project code is Apache 2.0 with Commons Clause v1.0; dependencies have separate terms.

See [DEVELOPMENT.md](DEVELOPMENT.md) for checks, [CONTRIBUTING.md](CONTRIBUTING.md) for contribution workflow, and [README.md](README.md), [FEATURES.md](FEATURES.md), [PRIVACY.md](PRIVACY.md) for user-facing details.
