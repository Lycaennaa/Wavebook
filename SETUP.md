# Development setup

Use these steps to prepare a macOS development environment. For the end-user release installation, see [INSTALLATION.md](INSTALLATION.md).

## Requirements

- macOS 15 or later, Xcode, Apple's Command Line Tools, and Git.
- Homebrew for installing the repository's tools.
- [just](https://github.com/casey/just). `just setup` cannot install `just` itself.

Install `just`, then run the repository setup recipe from the project root:

```sh
brew install just
just setup
```

`just setup` installs XcodeGen 2.46.0 or later and SwiftLint with Homebrew. It does not install Xcode, Apple's Command Line Tools, or `just`.

The local `just ci` recipe requires exactly Xcode 16.4 and Swift 6.1.2. See [DEVELOPMENT.md](DEVELOPMENT.md) for the local and hosted toolchain requirements and build/test commands.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the source layout and [CONTRIBUTING.md](CONTRIBUTING.md) for change and pull-request expectations.