# Security

## Reporting a vulnerability

Do not disclose an unpatched vulnerability in a public issue, pull request, or discussion.

Use GitHub's private **Report a vulnerability** flow in the repository's **Security** tab when that feature is enabled. This repository currently does not publish a security email address, supported-version matrix, or response-time SLA. If private vulnerability reporting is unavailable, contact the maintainers through a private GitHub channel and do not include secrets in a public issue.

Include only the information needed to reproduce the issue:

- Affected commit, release tag, or build.
- macOS version and installation source.
- Reproduction steps and expected/actual behavior.
- Any relevant logs with credentials, private paths, and personal library metadata removed.
- A safe contact method for follow-up.

Wait for maintainer guidance before publishing exploit details. Do not send passwords, signing material, private music files, or an entire user database in a report.

## Scope notes

Wavebook reads user-selected files with App Sandbox disabled in the direct-download build. It also sends selected track metadata to LRCLIB during lyric lookup. See [PRIVACY.md](PRIVACY.md) before reporting behavior that is an intended consequence of those designs.