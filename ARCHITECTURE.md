# Architecture

## Project structure

- `project.yml` is the XcodeGen source for the macOS app and `WavebookCore` framework. The app target depends on and embeds the core framework.
- `Wavebook/App/` contains the AppKit interface and app coordination.
- `Wavebook/Sources/WavebookCore/` contains library, playback, database, lyrics, and analysis code.
- `Wavebook/Package.swift` defines the standalone `WavebookCore` Swift package product and its tests. The package uses GRDB and SQLite.
- `Wavebook/Tests/WavebookCoreTests/` contains core tests.

## Data boundaries

Wavebook operates on selected local library folders and stores its catalog and preferences locally. Optional lyric lookup sends selected metadata to LRCLIB; downloaded lyric sidecars are written beside their audio files. See [PRIVACY.md](PRIVACY.md) for the current read, write, and network boundaries.

Edit `project.yml` for project structure changes and regenerate local Xcode files with `just generate-project`. See [DEVELOPMENT.md](DEVELOPMENT.md) for build and test commands.