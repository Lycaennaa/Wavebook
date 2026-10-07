# Features

The following describes capabilities visible in the current source tree. Listed audio extensions identify scan candidates; playback and metadata support can vary by file.

## User Interface and Visuals
- AppKit only.
- Light/Dark/AMOLED Black theme

## Library and discovery

- Add one or more local folders and scan files with `mp3`, `flac`, `opus`, `m4a`, `aac`, `wav`, `aif`, `aiff`, `aifc`, and `caf` filename extensions.
- Fresh installs open a welcome screen, guided folder step, and personalization step; multiple folders can be managed while scans run, with per-folder scanned/total audio progress and a prominent count of tracks matched to local lyrics for the most recently completed folder scan, plus recovery guidance for empty or failed scans. Help or Settings reopens onboarding with current folders and preferences. Removing a folder requires confirmation, removes its indexed tracks from Wavebook, and never deletes files from disk.
- Manage library folders in Settings or onboarding; removing a folder removes its indexed tracks from Wavebook without deleting files from disk.
- Browse and search songs, artists, albums, and genres; navigate between related catalog entries.
- Read audio metadata and display embedded artwork or supported sidecar images named `cover`, `folder`, or `front`.

## Playback and queue

- Play local tracks; play, pause, seek, skip to the previous or next track, shuffle, and repeat off, all, or one.
- Add tracks to the queue or insert them next; remove queued tracks and drag to reorder the queue.
- Control playback with macOS media keys and system playback commands.
- View, zoom, and pan a playback waveform; seek by clicking or dragging on it.
- Create track-specific skip segments and optionally skip detected silence at the start and end of songs.
- Select an audio output device and adjust playback volume.

## Playlists and favorites

- Mark tracks as favorites and use the built-in **Recently Added**, **Most Played**, **Favorites**, and **Lyrics** playlists. Filter Lyrics by tracks with or without an indexed `.lrc` file.
- Create, rename, and delete manual or smart playlists. Reorder and remove items in manual playlists; unavailable tracks retain their saved display details until cleared.
- Define smart-playlist rules as JSON and choose a supported sort field and direction.
- Add selected tracks to manual playlists.

## Lyrics, artwork, and file access

- Read `.lrc` lyrics associated with indexed library content. Timestamped lyrics support synchronized line highlighting, click-to-seek, and optional automatic scrolling.
- Search LRCLIB and download selected results as `.lrc` sidecars next to the corresponding audio files. Search sends only checked, non-empty metadata to `lrclib.net`; no audio files are sent.
- Open audio and available lyric files in another installed app, or reveal files in Finder.

## Audio processing

- Apply ReplayGain to help keep songs at a more consistent volume, in track or album mode, using available ReplayGain or R128 values.
- Analyze selected tracks or albums, review analysis status and failures, configure file concurrency, cancel work, and rescan analysis; results are cached locally.
- Use a personal 31-band EQ with preamp, bypass, reset-to-flat, and text import controls. Profiles are saved separately per output device.

## Listening history and appearance

- Record qualified listening history locally. View yearly and lifetime summaries, plays-per-day heatmaps, day timelines, rankings for songs, albums, artists, and genres, and top-skipped songs.
- Enable private listening to stop recording history, or reset stored listening history.
- Use System appearance by default, or choose Light, Dark, or AMOLED Black. Playback preferences such as volume, output device, ReplayGain, equalizer, and silence skipping persist locally.

See [PRIVACY.md](PRIVACY.md) for what these features read, write, and send outside the Mac.