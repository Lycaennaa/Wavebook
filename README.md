# Wavebook

Wavebook is a fully swift and appkit music player for local audio libraries with lots of features for macOS 15 or later. Light/Dark/AMOLED Black theme. Completely offline with optional lyric fetching.

First launch guides new installs through choosing local music folders. Reopen the welcome screen from Help or Settings.

## Why

I wanted a music player that was similar to ones found on mobile with a library but instead I only found ones focused on the folder or everything in a single list so I co-built Wavebook. I managed gpt-5.6-Luna, a little gpt-5.6-Sol and now gpt-6-Luna reviewed with [Cursor's Thermos Nuclear Code Quality Review](https://github.com/cursor/plugins/blob/main/thermos/skills/thermo-nuclear-code-quality-review/SKILL.md) and a custom adversarial skill with performance reviews where needed.

The main features is the AMOLED Black theme, a full 31 band parametric EQ, output picker, segment skipping, spotify esque lyrics and fully Appkit and Swift but theres others like replaygain too. Check [all of the features here](FEATURES.md).

## Download and use

Download the app ZIP and its matching `.sha256` file from this repository's Releases page. Verify the archive before opening it; replace `<version>` with the version in the filenames:

```sh
shasum -a 256 -c Wavebook-<version>.zip.sha256
```

GitHub also publishes build-provenance attestations for the ZIP and checksum. Verify both with the GitHub CLI, replacing `<version>` and `<owner>/<repo>` with the release values:

```sh
gh attestation verify "Wavebook-<version>.zip" --repo "<owner>/<repo>"
gh attestation verify "Wavebook-<version>.zip.sha256" --repo "<owner>/<repo>"
```

Attestations use the GitHub Actions identity; they do not require an Apple ID and do not replace macOS code signing or notarization.

Release builds are ad-hoc signed and not notarized, so Gatekeeper may warn on first launch. After verifying the checksum and GitHub provenance, extract the ZIP and move `Wavebook.app` to `/Applications`. If macOS blocks it, use Finder's Control-click > Open flow. If you intentionally choose to remove quarantine after verifying the download, run `xattr -dr com.apple.quarantine /Applications/Wavebook.app`; this targets the quarantine attribute only. The app bundle includes `LICENSE.txt` and `THIRD_PARTY_NOTICES.txt` in `Contents/Resources`.

## More information

- [Privacy and data stored or sent](PRIVACY.md)
- [Support and bug reports](SUPPORT.md)
- [Building and contributing](CONTRIBUTING.md)
- [License](LICENSE) — Apache 2.0 with Commons Clause License Condition v1.0; see the clause for its sale restriction.
- [Coding-agent guide](AGENTS.md)

Thank you tranxuanthang for [LRCLIB](https://github.com/tranxuanthang/lrclib)/[Lrcget](https://github.com/tranxuanthang/lrcget)