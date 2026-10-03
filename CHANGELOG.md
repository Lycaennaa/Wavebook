# Changelog

This file records user-visible changes when they are prepared for publication. The release workflow also generates GitHub release notes from version tags.

## Unreleased

- Arranged playback controls in a compact two-row grid on the right side of the player.
- Replaced the placeholder feature page with an implementation-based guide; corrected and expanded its capability descriptions to match the current source tree.
- Replayed standalone tracks when repeat all or repeat one is enabled.
- Queued selected artist, album, and playlist tracks within their full context and preserved repeat settings when queues change.
- Added repository documentation for installation, privacy, contribution, support, security, conduct, and third-party attribution.
- Preserved previously indexed tracks when descendant path resolution fails and rescan saved library roots at launch.
- Aborted reconciliation when failed-path preservation limits are exceeded, keeping existing catalog rows instead of risking data loss.
- Bounded startup library discovery with per-entry autorelease pools; the 250,000-entry limit counts directories and supported audio, LRC, and artwork sidecars, while unrelated files do not consume it. Over-limit scans preserve the existing catalog.
- Prevented the songs list from auto-loading pages against zero-size collection geometry during startup.
- Reuse cached track metadata on rescan when the file path, modification time, size, and bounded format preflight still match.
- Skip catalog reconciliation on fully unchanged rescans after revalidating audio fingerprints and lyric paths.
- Reconcile only changed or added tracks and prune missing paths without rewriting unchanged catalog rows.
- Added native app menus and made remote Play acknowledge an accepted asynchronous shuffle request.
- Deferred first Play-triggered shuffle until available saved library roots finish scanning.
- Attested release ZIPs and checksum files with GitHub Actions provenance; version-tag release notes are generated automatically.
- Included project and third-party license notices in release app bundles; corrected first-launch Gatekeeper instructions and added SwiftLint to CI and release checks.
- Expanded the reusable Release performance suite with medium/large library scans, EQ profile imports and AVAudioUnitEQ application, album ReplayGain, shuffled queue navigation, production waveform disk loading/drawing, and process memory/I/O/energy counters. Optimized shuffled queue transitions/current-index lookup, EQ profile application and band matching, waveform PCM aggregation/rendering, and LRC offset-adjustment allocation.

No published release entries are recorded in the current repository history.