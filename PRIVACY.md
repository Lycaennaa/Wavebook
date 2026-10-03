# Privacy and data flow

This document describes behavior implemented in the current Wavebook source tree. It does not describe LRCLIB's retention, logging, or privacy practices; those are controlled by LRCLIB and may change. This app does not make ANY network requests besides LRCLIB ONLY when you click search.

## Data kept on the Mac

- Wavebook reads selected library folders to discover audio files, `.lrc` lyrics, metadata, and artwork.
- The catalog, playlist data, ReplayGain analysis state, and listening history are stored in `~/Library/Application Support/Wavebook/Library.sqlite`.
- Wavebook stores downloaded lyrics as an `.lrc` file beside the corresponding audio file. Existing sidecars can also be read from indexed library content.
- Equalizer, appearance, and related app settings are stored locally by the app.

## Network requests

Lyrics lookup is the documented network integration. Wavebook sends HTTPS requests to `lrclib.net` when a user searches for or downloads lyrics. A user must click "search LRCLIB" to do a network request to LRCLIB.

- A direct track lookup sends the track title, artist, album, and duration as query parameters.
- A search sends whichever user or track metadata is present, including track name, artist name, album name, and search keywords.
- A download may perform a direct lookup followed by a search fallback when the direct result does not provide a usable synchronized lyric result.
- The downloader uses an ephemeral URL session, does not use a local request cache, and rejects redirects outside `https://lrclib.net` and its subdomains.
- Network requests can fail because of missing metadata, no internet connection, an unavailable service, an invalid response, or no matching lyrics. The app does not treat a failed lyric lookup as a library-scan failure.

The source does not define how LRCLIB retains or processes request data. Review the service's current information before enabling lyric lookup for sensitive metadata.

## Permissions and filesystem access

The direct-download build disables App Sandbox so it can work with user-selected music folders and write adjacent lyric sidecars. Access is still constrained by macOS permissions and privacy controls. macOS may require the user to grant access to a protected folder or Full Disk Access.

Review release assets before opening them. Do not add a library folder unless you want Wavebook to read its supported audio, artwork, metadata, and lyric files.

## Listening-history controls

Listening history is local. Private listening-history mode prevents new playback sessions from being persisted while it is enabled. Resetting history is a separate action that removes the stored listening-history data. Neither control changes the audio files in the selected library.