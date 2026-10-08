import AppKit
import WavebookCore

final class PlayerBarView: ThemeBackgroundView {
    var onTogglePlayback: (() -> Void)?
    var onPreviousPlayback: (() -> Void)?
    var onNextPlayback: (() -> Void)?
    var onToggleShuffle: (() -> Void)?
    var onCycleRepeatMode: (() -> Void)?
    var onCycleReplayGainMode: (() -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onEqualizerRequested: (() -> Void)?
    var onOutputDeviceRequested: ((NSButton) -> Void)?
    var onLyricsRequested: (() -> Void)?
    var onTogglePrivateMode: (() -> Void)?
    var onToggleFavorite: ((Track) -> Void)?
    var onSkipSegmentsRequested: (() -> Void)?

    var onAlbumSelect: ((AlbumKey) -> Void)?
    var onArtistSelect: ((String) -> Void)?
    var onGenreSelect: ((String) -> Void)?
    private let artworkView = ArtworkImageView()
    private let titleLabel = MarqueeLabel()
    private let artistLabel = MarqueeLabel()
    private let albumLabel = MarqueeLabel()
    private let genreLabel = MarqueeLabel()
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let controlsView = PlaybackBarControlsView()
    private let lyricsButton = NSButton(title: "", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "", target: nil, action: nil)
    private var lyricsPreview = LyricsPlaybackPreview.unavailable
    private var currentTrack: Track?
    private var selectionMenu: NSMenu?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
        configureArtworkAndMetadata()
        configureProgressControls()
        configureControlCallbacks()
        configureLyricsButton()
        configureLayout()
    }

    private func configureAppearance() {
        wantsLayer = true
        layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: self)
        layer?.borderWidth = 1
    }

    private func configureArtworkAndMetadata() {
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 8
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = AppTheme.secondaryText
        albumLabel.font = .systemFont(ofSize: 12)
        albumLabel.textColor = AppTheme.secondaryText
        genreLabel.font = .systemFont(ofSize: 12)
        genreLabel.textColor = AppTheme.secondaryText
        artistLabel.onPress = { [weak self] in self?.selectArtist() }
        albumLabel.onPress = { [weak self] in self?.selectAlbum() }
        genreLabel.onPress = { [weak self] in self?.selectGenre() }
        artistLabel.setAccessibilityLabel("Go to Artist")
        albumLabel.setAccessibilityLabel("Go to Album")
        genreLabel.setAccessibilityLabel("Go to Genre")
    }

    private func configureProgressControls() {
        progressSlider.isEnabled = false
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged)
        progressSlider.isContinuous = false
        progressSlider.controlSize = .small
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = AppTheme.secondaryText
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
    }

    private func configureControlCallbacks() {
        controlsView.onTogglePlayback = { [weak self] in self?.onTogglePlayback?() }
        controlsView.onPreviousPlayback = { [weak self] in self?.onPreviousPlayback?() }
        controlsView.onNextPlayback = { [weak self] in self?.onNextPlayback?() }
        controlsView.onToggleShuffle = { [weak self] in self?.onToggleShuffle?() }
        controlsView.onCycleRepeatMode = { [weak self] in self?.onCycleRepeatMode?() }
        controlsView.onCycleReplayGainMode = { [weak self] in self?.onCycleReplayGainMode?() }
        controlsView.onEqualizerRequested = { [weak self] in self?.onEqualizerRequested?() }
        controlsView.onOutputDeviceRequested = { [weak self] button in
            self?.onOutputDeviceRequested?(button)
        }
        controlsView.onTogglePrivateMode = { [weak self] in self?.onTogglePrivateMode?() }
        controlsView.onSkipSegmentsRequested = { [weak self] in self?.onSkipSegmentsRequested?() }
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.setAccessibilityLabel("Playback Position")
        volumeSlider.setAccessibilityLabel("Output Device Volume")
        volumeSlider.toolTip = "Adjust volume for the current output device"
    }

    private func configureLyricsButton() {
        lyricsButton.isBordered = false
        lyricsButton.font = .systemFont(ofSize: 13, weight: .medium)
        lyricsButton.contentTintColor = NSColor.secondaryLabelColor
        lyricsButton.target = self
        lyricsButton.action = #selector(showLyrics)
        favoriteButton.isBordered = false
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.contentTintColor = AppTheme.accent
        favoriteButton.setAccessibilityLabel("Favorite")
        lyricsButton.isEnabled = false
        lyricsButton.wantsLayer = true
        lyricsButton.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: lyricsButton)
        lyricsButton.layer?.cornerRadius = 7
        lyricsButton.cell?.lineBreakMode = .byTruncatingTail
        lyricsButton.setAccessibilityLabel("Open Lyrics")
        lyricsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureLayout() {
        let metadataStack = NSStackView(views: [titleLabel, artistLabel, albumLabel, genreLabel])
        metadataStack.orientation = .vertical
        metadataStack.spacing = 2
        let volumeLabel = NSTextField(labelWithString: "Vol")
        volumeLabel.textColor = AppTheme.secondaryText
        let volumeStack = NSStackView(views: [volumeLabel, volumeSlider])
        volumeStack.orientation = .horizontal
        volumeStack.spacing = 8
        volumeSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let infoStack = NSStackView(views: [metadataStack, volumeStack])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 8
        metadataStack.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        infoStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let leftStack = NSStackView(views: [artworkView, infoStack, favoriteButton])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.distribution = .fill
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsView.setContentHuggingPriority(.required, for: .horizontal)
        leftStack.spacing = 12
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
        let contentStack = NSStackView(views: [leftStack, spacer, controlsView])
        contentStack.orientation = .horizontal
        contentStack.distribution = .fill
        contentStack.alignment = .centerY
        contentStack.spacing = 18
        let progressStack = NSStackView(views: [progressSlider, timeLabel])
        progressStack.orientation = .horizontal
        progressStack.alignment = .centerY
        progressStack.spacing = 10
        let stack = NSStackView(views: [contentStack, progressStack, lyricsButton])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 58),
            artworkView.heightAnchor.constraint(equalToConstant: 58),
            lyricsButton.heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    override func themeDidChange() {
        super.themeDidChange()
        controlsView.updateThemeAppearance()
        layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: self)
        artworkView.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: artworkView)
        lyricsButton.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: lyricsButton)
        updateLyricsButtonTint()
    }

    func set(track: Track, artwork: NSImage?, duration: TimeInterval, isPlaying: Bool) {
        menu?.cancelTracking()
        selectionMenu?.cancelTracking()
        selectionMenu = nil
        currentTrack = track

        controlsView.setTrackAvailable(true)
        let navigationMenu = makeNavigationMenu(for: track)
        menu = navigationMenu
        for view in [artworkView, titleLabel, artistLabel, albumLabel, genreLabel] {
            view.menu = navigationMenu
        }
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artists.joined(separator: ", ")
        albumLabel.stringValue = track.albumTitle
        genreLabel.stringValue = track.genres.joined(separator: ", ")
        updateFavoriteButton(track.isFavorite)
        artworkView.setArtwork(artwork)
        setProgress(elapsed: 0, duration: duration)
        setPlaying(isPlaying)
    }
    private func updateFavoriteButton(_ favorite: Bool) {
        favoriteButton.image = NSImage(
            systemSymbolName: favorite ? "star.fill" : "star",
            accessibilityDescription: favorite ? "Unfavorite" : "Favorite"
        )
        favoriteButton.toolTip = favorite ? "Unfavorite" : "Favorite"
        favoriteButton.isEnabled = currentTrack != nil
    }
    func updateFavoriteState(trackID: Int64, isFavorite: Bool) {
        guard currentTrack?.id == trackID else { return }
        currentTrack?.isFavorite = isFavorite
        updateFavoriteButton(isFavorite)
    }

    @objc private func toggleFavorite() {
        guard let currentTrack else { return }
        onToggleFavorite?(currentTrack)
    }

    func clearTrack() {
        menu?.cancelTracking()
        selectionMenu?.cancelTracking()
        selectionMenu = nil
        menu = nil
        currentTrack = nil
        updateFavoriteButton(false)
        controlsView.setTrackAvailable(false)
        titleLabel.stringValue = ""
        artistLabel.stringValue = ""
        albumLabel.stringValue = ""
        genreLabel.stringValue = ""
        artworkView.setArtwork(nil)
        setProgress(elapsed: 0, duration: 0)
        setLyricsEnabled(false)
        setLyricsPreview(.unavailable)
        setPlaying(false)
    }

    func setPlaying(_ isPlaying: Bool) {
        controlsView.setPlaying(isPlaying)
    }

    func setProgress(elapsed: TimeInterval, duration: TimeInterval) {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeElapsed = elapsed.isFinite ? min(max(elapsed, 0), safeDuration) : 0
        progressSlider.isEnabled = safeDuration > 0
        progressSlider.maxValue = max(safeDuration, 1)
        progressSlider.doubleValue = safeElapsed
        timeLabel.stringValue = "\(Self.timeString(safeElapsed)) / \(Self.timeString(safeDuration))"
    }

    func setVolume(_ volume: Float) {
        volumeSlider.doubleValue = min(max(Double(volume), 0), 1)
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        controlsView.setEqualizerEnabled(enabled)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        controlsView.setShuffleEnabled(enabled)
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        controlsView.setRepeatMode(mode)
    }

    func setReplayGainMode(_ mode: ReplayGainMode) {
        controlsView.setReplayGainMode(mode)
    }

    func setLyricsEnabled(_ enabled: Bool) {
        lyricsButton.isEnabled = enabled
        updateLyricsButtonTint()
    }

    func setLyricsPreview(_ value: LyricsPlaybackPreview) {
        lyricsPreview = value
        let title = Self.lyricsPreviewText(value)
        lyricsButton.title = title
        lyricsButton.setAccessibilityValue(title)
        updateLyricsButtonTint()
    }

    private func updateLyricsButtonTint() {
        lyricsButton.contentTintColor = lyricsButton.isEnabled && lyricsPreview.isCurrent
            ? AppTheme.primaryText
            : NSColor.secondaryLabelColor
    }

    private static func lyricsPreviewText(_ preview: LyricsPlaybackPreview) -> String {
        switch preview {
        case .unavailable:
            return "No Lyrics"
        case .loading:
            return "Loading Lyrics…"
        case let .waiting(firstLine, timeUntil):
            if timeUntil <= 2 {
                return lyricText(firstLine.text)
            }
            let countdown = PlaybackTimecode.string(
                from: ceil(timeUntil),
                includingFractionalSeconds: false
            )
            let timestamp = PlaybackTimecode.string(
                from: firstLine.time,
                includingFractionalSeconds: true
            )
            return "in \(countdown) · at \(timestamp) · \(lyricText(firstLine.text))"
        case let .current(line):
            return lyricText(line.text)
        case let .untimed(line):
            return lyricText(line.text)
        case .instrumental:
            return "Instrumental"
        }
    }

    private static func lyricText(_ text: String) -> String {
        let compact = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? "♪" : "♪  \(compact)"
    }

    func setPrivateMode(_ enabled: Bool) {
        controlsView.setPrivateMode(enabled)
    }

    @objc private func volumeChanged() {
        onVolumeChanged?(Float(volumeSlider.doubleValue))
    }

    @objc private func progressChanged() {
        onSeek?(progressSlider.doubleValue)
    }

    @objc private func showLyrics() {
        onLyricsRequested?()
    }

    @objc private func showSkipSegments() {
        onSkipSegmentsRequested?()
    }

    @objc private func openAlbum(_ sender: NSMenuItem) {
        guard let albumKey = sender.representedObject as? AlbumKey else { return }
        onAlbumSelect?(albumKey)
    }

    @objc private func openArtist(_ sender: NSMenuItem) {
        guard let artist = sender.representedObject as? String else { return }
        onArtistSelect?(artist)
    }

    @objc private func openGenre(_ sender: NSMenuItem) {
        guard let genre = sender.representedObject as? String else { return }
        onGenreSelect?(genre)
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private extension PlayerBarView {
    private func selectAlbum() {
        guard onAlbumSelect != nil, let currentTrack else { return }
        onAlbumSelect?(currentTrack.albumKey)
    }
    private func selectArtist() {
        guard onArtistSelect != nil, let currentTrack else { return }
        let artists = currentTrack.artists
        guard artists.count > 1 else {
            onArtistSelect?(artists.first ?? "")
            return
        }
        showSelectionMenu(values: artists, action: #selector(openArtist), from: artistLabel)
    }

    private func selectGenre() {
        guard onGenreSelect != nil, let currentTrack else { return }
        let genres = currentTrack.genres
        guard genres.count > 1 else {
            onGenreSelect?(genres.first ?? "")
            return
        }
        showSelectionMenu(values: genres, action: #selector(openGenre), from: genreLabel)
    }

    private func showSelectionMenu(values: [String], action: Selector, from view: NSView) {
        selectionMenu?.cancelTracking()
        let menu = NSMenu()
        for value in values {
            menu.addItem(navigationItem(title: value, value: value, action: action))
        }
        selectionMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        if selectionMenu === menu {
            selectionMenu = nil
        }
    }

    private func makeNavigationMenu(for track: Track) -> NSMenu? {
        let menu = NSMenu()
        if onAlbumSelect != nil {
            let item = NSMenuItem(title: "Go to Album", action: #selector(openAlbum(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = track.albumKey
            menu.addItem(item)
        }
        if onArtistSelect != nil {
            addNavigationItem(title: "Go to Artist", values: track.artists, action: #selector(openArtist), to: menu)
        }
        if onGenreSelect != nil {
            addNavigationItem(title: "Go to Genre", values: track.genres, action: #selector(openGenre), to: menu)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func addNavigationItem(title: String, values: [String], action: Selector, to menu: NSMenu) {
        let values = values.isEmpty ? [""] : values
        if values.count == 1 {
            menu.addItem(navigationItem(title: title, value: values[0], action: action))
            return
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for value in values {
            submenu.addItem(navigationItem(title: value, value: value, action: action))
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    private func navigationItem(title: String, value: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }
}
