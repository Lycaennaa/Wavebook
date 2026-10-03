# Support

Read the [README](README.md), [FEATURES.md](FEATURES.md), and [PRIVACY.md](PRIVACY.md) before opening a request. The project is a local-library macOS app; the most useful reports include the exact environment and the local files involved without exposing private metadata.

## Bug reports

Use a GitHub issue for a reproducible bug. Include:

- macOS version.
- Wavebook version and build, or the commit used to build it.
- Whether the app came from a GitHub Release or was built from source.
- Steps to reproduce, expected behavior, and actual behavior.
- The affected feature: scanning, catalog, playback, queue, playlist, lyrics, ReplayGain, equalizer, history, or release packaging.
- Relevant error text or a redacted log excerpt.

Remove music paths, account information, personal metadata, checksums for private files, and other sensitive data before posting. Do not attach an audio library or a database unless it has been reviewed and intentionally sanitized.

## Feature requests

Describe the use case, the local workflow it improves, and any relevant audio-file, library, or macOS constraints. A request should not assume App Store distribution, notarization, or automatic updates; those are not part of the current distribution model.

## Release and checksum problems

For a downloaded release, report the tag, asset name, checksum command result, and macOS error. Do not bypass a checksum mismatch or Gatekeeper warning by default; first verify that the ZIP and checksum came from the same GitHub Release.

## Security issues

Do not use a public issue for an unpatched vulnerability. Follow [SECURITY.md](SECURITY.md).

No support response time or supported-version matrix is promised in this repository.