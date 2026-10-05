# Contributing

Wavebook is a macOS Swift application with a shared XcodeGen project and a standalone `WavebookCore` Swift package.

## Development requirements

- macOS 15.0 or later.
- Xcode 26.6 or later.
- Git and Apple's Command Line Tools.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 or later when regenerating the project.
- The repository's `justfile` recipes also require the tools named by those recipes, including `[just](https://github.com/casey/just)` and SwiftLint where applicable. This justfile is for convenience.

## Project layout

- `Wavebook/App` — macOS application UI and app coordination.
- `Wavebook/Sources/WavebookCore` — reusable library, playback, lyrics, database, and analysis code.
- `Wavebook/Tests/WavebookCoreTests` — Swift and XCTest coverage for the core module.
- `project.yml` — canonical XcodeGen input.
- `.github/workflows` — CI and release workflows.
- `scripts` — package, privacy, lockfile, and generated-project checks.

## Local checks

Run commands from the repository root.

Regenerate and verify the committed Xcode project when `project.yml` changes:

```sh
xcodegen generate --spec project.yml
git diff --exit-code -- Wavebook.xcodeproj
```

Run the repository checks when their tools are installed:

```sh
just ci
just test
just lint
```

`just ci` mirrors the workflow checks and verifies the current runner's Xcode 16.4 / Swift 6.1.2 toolchain. For exact local parity, select Xcode with:

```sh
WAVEBOOK_DEVELOPER_DIR="/Applications/Xcode16.4.app/Contents/Developer" just ci
```

Xcode 16.4 can be downloaded at https://developer.apple.com/download/all.

The local `just build`, `just build-release`, and `just test` recipes reuse `.build/derived-data`, including its SwiftPM checkout and module caches, avoiding duplicate package clones. Local packaging reuses those Release products and stages its signed/stripped app copy outside the cache. `just test` removes its result bundle after a successful run and retains `.build/test-results.xcresult` on failure for crash diagnostics. Remove `.build/derived-data` when no build is running to reclaim space; delete the failure result after exporting needed attachments. The release workflow shares DerivedData between tests and packaging. Update the pinned local versions when CI's toolchain changes. `project.yml`'s `xcodeVersion` is XcodeGen metadata, not a toolchain selector.

## Change expectations

- Add or update tests beside the affected `WavebookCore` behavior when a change affects behavior.
- Keep user-facing behavior, permissions, network requests, persistence, and failure behavior documented when they change.
- Do not edit generated Xcode project data as a substitute for changing `project.yml`.
- Keep dependency pins and their notices synchronized when dependencies change.
- Do not commit credentials, private library paths, generated build output, or user data.
- Include the commands run and any known failures in a pull request description.

## Pull requests

A pull request should state:

1. What changed and why.
2. Which user-facing or data-flow behavior changed.
3. What checks were run and their results including reviews.
4. Any known limitation, migration, or release-readiness impact.
5. Which LLM model and reasoning level if any was used.

Use [SUPPORT.md](SUPPORT.md) for bug-report details and [SECURITY.md](SECURITY.md) for vulnerabilities. Wavebook project-owned material is licensed under the Apache License 2.0 with Commons Clause License Condition v1.0; contributions and reuse remain subject to [LICENSE](LICENSE).
