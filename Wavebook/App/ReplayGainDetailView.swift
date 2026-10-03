import AppKit
import WavebookCore

final class ReplayGainDetailView: ThemeAwareView {
    var onRefresh: (() -> Void)?

    private let currentTrackLabel = NSTextField(wrappingLabelWithString: "No current track")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "Mode: Off")
    private let effectiveGainLabel = NSTextField(wrappingLabelWithString: "Applied: Unity (0.0 dB)")
    private let cacheErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let trackValuesLabel = NSTextField(wrappingLabelWithString: "Unavailable")
    private let albumValuesLabel = NSTextField(wrappingLabelWithString: "Unavailable")
    private let analysisValuesLabel = NSTextField(wrappingLabelWithString: "State: No cached row")
    private var displayedTrackPath: String?
    private var displayedData: ReplayGainNormalizationData?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.panel, in: self)
        layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: self)
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        buildUI()
        set(track: nil, data: nil, mode: .off, playbackGainDB: nil, cacheError: nil)
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func themeDidChange() {
        super.themeDidChange()
        layer?.backgroundColor = AppTheme.cgColor(AppTheme.panel, in: self)
        layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: self)
    }

    func set(
        track: Track?,
        data: ReplayGainNormalizationData?,
        mode: ReplayGainMode,
        playbackGainDB: Double?,
        cacheError: String?
    ) {
        let isSameTrack = track?.path == displayedTrackPath
        if cacheError == nil {
            displayedData = data
        } else if !isSameTrack {
            displayedData = nil
        }
        displayedTrackPath = track?.path

        if let track {
            let artist = track.artistDisplay
            currentTrackLabel.stringValue = artist.isEmpty ? track.title : "\(track.title) — \(artist)"
            pathLabel.stringValue = track.path
            pathLabel.toolTip = track.path
        } else {
            currentTrackLabel.stringValue = "No current track"
            pathLabel.stringValue = "Start playback to inspect cached loudness values."
            pathLabel.toolTip = nil
        }

        cacheErrorLabel.stringValue = cacheError.map { "Cache read failed: \($0)" } ?? ""
        cacheErrorLabel.isHidden = cacheError == nil
        modeLabel.stringValue = "Mode: \(Self.modeName(mode))"
        effectiveGainLabel.stringValue = Self.effectiveGainText(
            mode: mode,
            data: displayedData,
            playbackGainDB: playbackGainDB
        )
        trackValuesLabel.stringValue = Self.scopeText(displayedData?.track)
        albumValuesLabel.stringValue = Self.scopeText(displayedData?.album)
        analysisValuesLabel.stringValue = cacheError != nil && displayedData == nil
            ? "State:       Cache read failed\nCached values could not be loaded."
            : Self.analysisText(displayedData)
    }

    private func buildUI() {
        let header = makeHeader()
        configureValueLabels()
        let glossaryLabel = makeGlossaryLabel()
        let sections = makeSections()
        let stack = makeStack(header: header, glossaryLabel: glossaryLabel, sections: sections)
        addSubview(stack)
        activateLayout(stack: stack, header: header, glossaryLabel: glossaryLabel, sections: sections)
    }

    private func makeHeader() -> NSStackView {
        let title = NSTextField(labelWithString: "ReplayGain details")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = AppTheme.primaryText
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.contentTintColor = AppTheme.accent
        refreshButton.toolTip = "Reload cached values without rescanning the audio file"
        refreshButton.setAccessibilityLabel("Refresh ReplayGain details")
        let header = NSStackView(views: [title, NSView(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        return header
    }

    private func configureValueLabels() {
        currentTrackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        currentTrackLabel.textColor = AppTheme.primaryText
        currentTrackLabel.maximumNumberOfLines = 2
        currentTrackLabel.lineBreakMode = .byTruncatingTail
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = AppTheme.secondaryText
        pathLabel.maximumNumberOfLines = 2
        pathLabel.lineBreakMode = .byTruncatingMiddle
        modeLabel.textColor = AppTheme.secondaryText
        effectiveGainLabel.textColor = AppTheme.accent
        effectiveGainLabel.font = .systemFont(ofSize: 13, weight: .medium)
        effectiveGainLabel.maximumNumberOfLines = 2
        cacheErrorLabel.textColor = .systemRed
        cacheErrorLabel.maximumNumberOfLines = 2
        cacheErrorLabel.isHidden = true
    }

    private func makeGlossaryLabel() -> NSTextField {
        let glossaryText = "Glossary — Gain: loudness adjustment. "
            + "LUFS: perceived loudness. Sample peak: highest sample level. "
            + "Headroom: safe boost before clipping. Clamped: gain after boost and peak limits."
        let label = NSTextField(wrappingLabelWithString: glossaryText)
        label.font = .systemFont(ofSize: 10)
        label.textColor = AppTheme.secondaryText
        label.maximumNumberOfLines = 4
        return label
    }

    private func makeSections() -> [NSView] {
        [
            section(title: "Track values", valueLabel: trackValuesLabel),
            section(title: "Album values", valueLabel: albumValuesLabel),
            section(title: "Cache / analysis", valueLabel: analysisValuesLabel)
        ]
    }

    private func makeStack(
        header: NSStackView,
        glossaryLabel: NSTextField,
        sections: [NSView]
    ) -> NSStackView {
        let stack = NSStackView(views: [
            header,
            currentTrackLabel,
            pathLabel,
            modeLabel,
            effectiveGainLabel,
            cacheErrorLabel,
            glossaryLabel,
            separator(),
            sections[0],
            separator(),
            sections[1],
            separator(),
            sections[2]
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func activateLayout(
        stack: NSStackView,
        header: NSStackView,
        glossaryLabel: NSTextField,
        sections: [NSView]
    ) {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            currentTrackLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            effectiveGainLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cacheErrorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            glossaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sections[0].widthAnchor.constraint(equalTo: stack.widthAnchor),
            sections[1].widthAnchor.constraint(equalTo: stack.widthAnchor),
            sections[2].widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

}
extension ReplayGainDetailView {
    private func section(title: String, valueLabel: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText

        valueLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.textColor = AppTheme.secondaryText
        valueLabel.maximumNumberOfLines = 0
        valueLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        valueLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func refresh() {
        onRefresh?()
    }

    private static func scopeText(_ values: ReplayGainScopeValues?) -> String {
        guard let values else {
            return [
                "Status:      Unavailable",
                "Source:      —",
                "Gain:        —",
                "Integrated:  —",
                "Sample peak: —",
                "Headroom:    —",
                "Clamped:     —"
            ].joined(separator: "\n")
        }

        let gain = values.gain?.decibels
        let source = values.gain.map { sourceName($0.source) } ?? "—"
        let integrated = values.gain?.source == .measured
            ? gain.map { lufs(ReplayGain.targetLUFS - $0) } ?? "—"
            : "—"
        let peak = values.samplePeak.map { "\(decimal($0, places: 6)) (\(dbFS($0)))" } ?? "—"
        let headroom = values.samplePeak.flatMap { ReplayGain.headroomDB(samplePeak: $0) }.map(db) ?? "—"
        let applied = ReplayGain.appliedGainDB(for: values)
        let appliedText = applied.map { "\(db($0)) (\(bindingConstraint(values: values, applied: $0)))" } ?? "—"

        return [
            "Status:      \(values.isReady ? "Ready" : "Incomplete")",
            "Source:      \(source)",
            "Gain:        \(gain.map(db) ?? "—")",
            "Integrated:  \(integrated)",
            "Sample peak: \(peak)",
            "Headroom:    \(headroom)",
            "Clamped:     \(appliedText)"
        ].joined(separator: "\n")
    }

    private static func effectiveGainText(
        mode: ReplayGainMode,
        data: ReplayGainNormalizationData?,
        playbackGainDB: Double?
    ) -> String {
        let cached = cachedTarget(mode: mode, data: data)
        guard let playbackGainDB else {
            return "Playback target: —\nCached target: \(db(cached.gain)) — \(cached.scope)"
        }
        guard abs(playbackGainDB - cached.gain) >= 0.005 else {
            return "Playback target: \(db(playbackGainDB)) — \(cached.scope)"
        }
        return "Playback target: \(db(playbackGainDB)) — \(cached.scope)\n"
            + "Cached target: \(db(cached.gain)) — \(cached.scope), applies next play or mode change"
    }

    private static func cachedTarget(
        mode: ReplayGainMode,
        data: ReplayGainNormalizationData?
    ) -> (gain: Double, scope: String) {
        switch mode {
        case .off:
            return (0, "Normalization off")
        case .track:
            guard let applied = ReplayGain.appliedGainDB(for: data?.track) else {
                return (0, "Unity; track values unavailable")
            }
            return (applied, "Track")
        case .album:
            if let applied = ReplayGain.appliedGainDB(for: data?.album) {
                return (applied, "Album")
            }
            if let applied = ReplayGain.appliedGainDB(for: data?.track) {
                return (applied, "Track fallback")
            }
            return (0, "Unity; album and track values unavailable")
        }
    }

    private static func analysisText(_ data: ReplayGainNormalizationData?) -> String {
        guard let data else {
            return [
                "State:       No cached row",
                "Error:       —",
                "Track ID:    —",
                "Revision:    —",
                "Modified:    —",
                "File size:   —",
                "Album gen:   —",
                "Versions:    —"
            ].joined(separator: "\n")
        }

        let error: String
        if let reason = data.errorReason {
            let timestamp = data.errorAt.map { " @ \(date($0))" } ?? ""
            error = "\(reason)\(timestamp)"
        } else {
            error = "—"
        }
        let modified = data.fingerprint.modificationDate.map(date) ?? "—"
        let fileSize = data.fingerprint.fileSize.map(byteCount) ?? "—"
        let albumGeneration = data.albumGeneration ?? "—"

        return [
            "State:       \(stateName(data.state))",
            "Error:       \(error)",
            "Track ID:    \(data.trackID)",
            "Revision:    \(data.trackRevision)",
            "Modified:    \(modified)",
            "File size:   \(fileSize)",
            "Album gen:   \(albumGeneration)",
            "Versions:    analyzer \(data.analyzerVersion), tags \(data.tagSchemaVersion)"
        ].joined(separator: "\n")
    }

    private static func bindingConstraint(values: ReplayGainScopeValues, applied: Double) -> String {
        guard let gain = values.gain?.decibels,
              let peak = values.samplePeak,
              let headroom = ReplayGain.headroomDB(samplePeak: peak) else { return "not ready" }

        let tolerance = 0.000_001
        var constraints: [String] = []
        if abs(applied - gain) < tolerance { constraints.append("gain") }
        if abs(applied - ReplayGain.maximumBoostDB) < tolerance { constraints.append("+12 dB cap") }
        if abs(applied - headroom) < tolerance { constraints.append("peak clamp") }
        return constraints.joined(separator: ", ")
    }

    private static func sourceName(_ source: ReplayGainGainSource) -> String {
        switch source {
        case .replayGain: "ReplayGain tag"
        case .r128: "R128 tag"
        case .measured: "libebur128"
        }
    }

    private static func stateName(_ state: ReplayGainAnalysisState) -> String {
        switch state {
        case .pending: "Pending"
        case .running: "Running"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    private static func modeName(_ mode: ReplayGainMode) -> String {
        switch mode {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }

    private static func db(_ value: Double) -> String {
        String(format: "%+.2f dB", value)
    }

    private static func dbFS(_ peak: Double) -> String {
        String(format: "%+.2f dBFS", 20 * log10(peak))
    }

    private static func lufs(_ value: Double) -> String {
        String(format: "%.2f LUFS", value)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.*f", places, value)
    }

    private static func date(_ value: Date) -> String {
        DateFormatter.localizedString(from: value, dateStyle: .short, timeStyle: .medium)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
