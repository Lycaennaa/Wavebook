# Installation

Wavebook requires macOS 15 or later. Download the release ZIP from the repository's GitHub Releases page.

## Verify the download

GitHub displays a SHA-256 digest for each release asset. Calculate the ZIP's digest and compare it with GitHub's value before opening it. Replace `<version>` with the version in the asset filename.

```sh
shasum -a 256 "Wavebook-<version>.zip"
```

GitHub also publishes a build-provenance attestation. Verify it with the GitHub CLI; replace `<version>` and `<owner>/<repo>` with the release values:

```sh
gh attestation verify "Wavebook-<version>.zip" --repo "<owner>/<repo>"
```

Do not open the ZIP if either verification fails. The attestation uses the GitHub Actions identity; it does not require an Apple ID and does not replace macOS code signing or notarization.

## Install and open

After verifying the digest and attestation, extract the ZIP and move `Wavebook.app` to `/Applications`. The release app is ad-hoc signed and not notarized, so Gatekeeper may warn on first launch. If macOS blocks the app, first try Finder's Control-click > Open flow.

Only if you intentionally choose to remove quarantine after successful verification, run:

```sh
xattr -dr com.apple.quarantine /Applications/Wavebook.app
```

This removes the quarantine attribute from the app bundle. The bundle includes `LICENSE.txt` and `THIRD_PARTY_NOTICES.txt` in `Contents/Resources`.

## First launch

On first launch, choose one or more local music folders. Wavebook scans selected folders and indexes supported audio and lyric files. Removing a folder from Wavebook removes its indexed tracks but does not delete files from disk.

Lyrics search is optional. When you choose Search LRCLIB, Wavebook sends checked, non-empty metadata fields to `lrclib.net`; it does not upload audio. See [PRIVACY.md](PRIVACY.md) before searching sensitive metadata.

See [FEATURES.md](FEATURES.md) for capabilities, [SECURITY.md](SECURITY.md) for safe-use notes, and [SUPPORT.md](SUPPORT.md) for help.