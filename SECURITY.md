# Security and safe use

## Verify releases

Download release ZIPs from the repository's GitHub Releases page. Verify the GitHub-displayed SHA-256 digest and GitHub Actions build-provenance attestation before opening the app. Do not bypass a digest or attestation mismatch. See [INSTALLATION.md](INSTALLATION.md) for commands.

Release builds are ad-hoc signed and not notarized, so Gatekeeper may warn. The quarantine-removal command in INSTALLATION is optional; do not use it unless both release checks succeeded and you intentionally accept the risk.

## Files and network access

The direct-download build disables App Sandbox. Add only library folders you intend Wavebook to read. Removing a folder removes its indexed data from Wavebook but does not delete files from disk.

Lyrics lookup is optional and user initiated. Search sends checked, non-empty metadata to LRCLIB, not audio; downloaded `.lrc` files are saved beside their corresponding audio files. Avoid lyric searches for metadata you do not want sent to the service. See [PRIVACY.md](PRIVACY.md) for details.