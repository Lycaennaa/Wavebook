# Development

Wavebook is a macOS 15+ Swift and AppKit app. `project.yml` is the source for the generated Xcode project; do not edit generated project files. See [ARCHITECTURE.md](ARCHITECTURE.md) for the project layout and [SETUP.md](SETUP.md) to install development tools.

## Build and checks

Run repository commands from the root:

```sh
just generate-project
just build
just run
just test
just lint
just check
just ci
```

`just check` generates the project, validates repository tooling and metadata, runs SwiftLint, and runs tests. `just ci` performs those checks and builds Release. Use the smallest relevant check while iterating.

Toolchain requirements differ by workflow:

- GitHub CI accepts Xcode 16.4 or later and does not pin an exact Swift version.
- Local `just ci` requires exactly Xcode 16.4 and Swift 6.1.2. For that parity, select Xcode with:

  ```sh
  WAVEBOOK_DEVELOPER_DIR="/Applications/Xcode16.4.app/Contents/Developer" just ci
  ```

- The release workflow requires Xcode 26.6 or later.
- `project.yml`'s `xcodeVersion: "26.6"` sets XcodeGen project metadata; it does not select the compiler.

Xcode 16.4 is available from [Apple's downloads](https://developer.apple.com/download/all).

Some local Xcode, test, and SwiftLint recipes use Distill when installed and fall back to the native tools otherwise. Distill is optional.

## Project files and test results

Run `just generate-project` after changing `project.yml`. `Wavebook.xcodeproj` is generated and ignored, except its tracked SwiftPM lockfile. Keep that lockfile aligned with `Wavebook/Package.resolved`; `just check` validates the pins.

The justfile stores DerivedData and test results under the worktree's `.build/` directory. Build and test recipes share `.build/derived-data`. `just test` removes its result bundle on success and retains `.build/test-results.xcresult` on failure. Export failure attachments with:

```sh
xcrun xcresulttool export attachments --path .build/test-results.xcresult --output-path .build/test-attachments --only-failures
```

Remove `.build/derived-data` when no build is running to reclaim space; `just clean` removes `.build`.

See [CONTRIBUTING.md](CONTRIBUTING.md) for change and pull-request expectations.