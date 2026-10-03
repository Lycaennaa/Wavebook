import AppKit
import WavebookCore

final class EqualizerCurveView: ThemeAwareView {
    var profile = EqualizerProfile.flat() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 10, dy: 10)
        guard rect.minX.isFinite,
              rect.minY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0,
              profile.bandGains.count == EqualizerProfile.bandCount else {
            return
        }

        AppTheme.raised.setFill()
        bounds.fill()

        AppTheme.border.setStroke()
        NSBezierPath(rect: rect).stroke()

        let midY = rect.midY
        let zero = NSBezierPath()
        zero.move(to: NSPoint(x: rect.minX, y: midY))
        zero.line(to: NSPoint(x: rect.maxX, y: midY))
        zero.lineWidth = 1
        AppTheme.border.setStroke()
        zero.stroke()

        let line = NSBezierPath()
        for index in EqualizerProfile.frequencies.indices {
            let position = Double(index) / Double(EqualizerProfile.bandCount - 1)
            let gain = profile.isBypassed ? 0 : profile.preamp + profile.bandGains[index]
            guard gain.isFinite else { return }
            let clamped = min(max(gain, EqualizerProfile.minimumGain), EqualizerProfile.maximumGain)
            let xPosition = rect.minX + CGFloat(position) * rect.width
            let yPosition = midY - CGFloat(clamped / EqualizerProfile.maximumGain) * (rect.height / 2)
            let point = NSPoint(x: xPosition, y: yPosition)
            guard point.x.isFinite, point.y.isFinite else { return }
            if index == 0 {
                line.move(to: point)
            } else {
                line.line(to: point)
            }
        }
        line.lineWidth = 2
        AppTheme.accent.setStroke()
        line.stroke()
    }
}

final class EqualizerPanelController: NSWindowController, NSTextFieldDelegate {
    var onChange: ((EqualizerProfile) -> Void)?
    var onReplayGainRefresh: (() -> Void)? {
        get { replayGainDetailView.onRefresh }
        set { replayGainDetailView.onRefresh = newValue }
    }

    private var profile: EqualizerProfile {
        didSet { syncInfoLabels() }
    }
    private var outputDeviceName: String {
        didSet { syncInfoLabels() }
    }
    private var gainSliders: [NSSlider] = []
    private var gainValueFields: [NSTextField] = []
    private let curveView = EqualizerCurveView()
    private let replayGainDetailView = ReplayGainDetailView()
    private let outputDeviceLabel = NSTextField(labelWithString: "")
    private let equalizerLabel = NSTextField(labelWithString: "")
    private let preampSlider = NSSlider(
        value: 0,
        minValue: EqualizerProfile.minimumGain,
        maxValue: EqualizerProfile.maximumGain,
        target: nil,
        action: nil
    )
    private let preampValueField = NSTextField(string: "")
    private let bypassButton = NSButton(checkboxWithTitle: "Bypass", target: nil, action: nil)
    private let importText = EditingTextView()
    private let statusLabel = NSTextField(labelWithString: "Paste frequency/gain lines, one pair per line")

    init(profile: EqualizerProfile, outputDeviceName: String) {
        self.profile = profile
        self.outputDeviceName = outputDeviceName
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 740),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Equalizer"
        panel.contentMinSize = NSSize(width: 1_100, height: 740)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeContentView() -> NSView {
        let root = ThemeBackgroundView()

        let title = makeTitle()
        configureProfileControls()
        let preampStack = makePreampStack()

        let bandScroll = makeBandScroll()

        let importScroll = makeImportScroll()

        let applyImportButton = NSButton(title: "Apply Import", target: self, action: #selector(applyImport))
        let resetButton = NSButton(title: "Reset Flat", target: self, action: #selector(resetFlat))
        for button in [applyImportButton, resetButton] {
            button.bezelStyle = .rounded
            button.contentTintColor = AppTheme.accent
        }
        let buttonStack = NSStackView(views: [applyImportButton, resetButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10

        statusLabel.textColor = AppTheme.secondaryText

        let stack = NSStackView(
            views: [
                title, outputDeviceLabel, equalizerLabel, bypassButton, preampStack,
                curveView, bandScroll, importScroll, buttonStack, statusLabel
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let divider = NSBox()
        divider.boxType = .separator

        let contentStack = NSStackView(views: [stack, divider, replayGainDetailView])
        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 690),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalTo: stack.heightAnchor),
            replayGainDetailView.widthAnchor.constraint(equalToConstant: 320),
            replayGainDetailView.heightAnchor.constraint(equalTo: stack.heightAnchor),
            preampSlider.widthAnchor.constraint(equalToConstant: 470),
            curveView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            curveView.heightAnchor.constraint(equalToConstant: 120),
            bandScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            importScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return root
    }

    private func makeTitle() -> NSTextField {
        let title = NSTextField(labelWithString: "31-band EQ")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = AppTheme.primaryText
        return title
    }

    private func configureProfileControls() {
        for label in [outputDeviceLabel, equalizerLabel] {
            label.textColor = AppTheme.secondaryText
        }
        syncInfoLabels()
        bypassButton.target = self
        bypassButton.action = #selector(bypassChanged)
        bypassButton.state = profile.isBypassed ? .on : .off
        curveView.profile = profile
    }

    private func makePreampStack() -> NSStackView {
        let preampLabel = NSTextField(labelWithString: "Preamp")
        preampLabel.textColor = AppTheme.secondaryText
        preampSlider.doubleValue = profile.preamp
        preampSlider.target = self
        preampSlider.action = #selector(preampChanged)
        configureDBField(preampValueField, tag: -1)
        preampValueField.stringValue = Self.gainLabel(profile.preamp)
        let preampDBLabel = NSTextField(labelWithString: "dB")
        preampDBLabel.textColor = AppTheme.secondaryText
        let preampStack = NSStackView(
            views: [preampLabel, preampSlider, preampValueField, preampDBLabel]
        )
        preampStack.orientation = .horizontal
        preampStack.spacing = 10
        preampLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        preampValueField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return preampStack
    }

    private func makeBandScroll() -> NSScrollView {
        let bandStack = NSStackView()
        bandStack.orientation = .vertical
        bandStack.spacing = 2
        bandStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        bandStack.frame = NSRect(
            x: 0,
            y: 0,
            width: 690,
            height: CGFloat(EqualizerProfile.bandCount * 24 + 8)
        )
        for index in 0..<EqualizerProfile.bandCount {
            let label = NSTextField(labelWithString: Self.frequencyLabel(EqualizerProfile.frequencies[index]))
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = AppTheme.secondaryText
            let slider = NSSlider(
                value: profile.bandGains[index],
                minValue: EqualizerProfile.minimumGain,
                maxValue: EqualizerProfile.maximumGain,
                target: self,
                action: #selector(gainChanged(_:))
            )
            slider.tag = index
            let valueField = NSTextField(string: Self.gainLabel(profile.bandGains[index]))
            configureDBField(valueField, tag: index)
            let dbLabel = NSTextField(labelWithString: "dB")
            dbLabel.textColor = AppTheme.secondaryText
            let row = NSStackView(views: [label, slider, valueField, dbLabel])
            row.orientation = .horizontal
            row.spacing = 8
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            slider.widthAnchor.constraint(equalToConstant: 470).isActive = true
            valueField.widthAnchor.constraint(equalToConstant: 56).isActive = true
            dbLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true
            bandStack.addArrangedSubview(row)
            gainSliders.append(slider)
            gainValueFields.append(valueField)
        }
        let bandScroll = NSScrollView()
        bandScroll.hasVerticalScroller = true
        bandScroll.borderType = .noBorder
        bandScroll.backgroundColor = AppTheme.background
        bandScroll.drawsBackground = true
        bandScroll.documentView = bandStack
        bandScroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        return bandScroll
    }

    private func makeImportScroll() -> NSScrollView {
        importText.string = "20\t9.9\n25\t8.8\n32\t6.9"
        importText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        importText.textColor = AppTheme.primaryText
        importText.backgroundColor = AppTheme.raised
        importText.insertionPointColor = AppTheme.primaryText
        importText.isEditable = true
        importText.isSelectable = true
        importText.allowsUndo = true
        importText.isRichText = false
        importText.importsGraphics = false
        importText.drawsBackground = true
        importText.selectedTextAttributes = [
            .backgroundColor: AppTheme.accent,
            .foregroundColor: AppTheme.textOnAccent
        ]
        let importScroll = NSScrollView()
        importScroll.hasVerticalScroller = true
        importScroll.borderType = .lineBorder
        importScroll.backgroundColor = AppTheme.raised
        importScroll.drawsBackground = true
        importScroll.autohidesScrollers = false
        importText.minSize = NSSize(width: 0, height: importScroll.contentSize.height)
        importText.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        importText.isVerticallyResizable = true
        importText.isHorizontallyResizable = false
        importText.autoresizingMask = [.width]
        importText.textContainer?.containerSize = NSSize(
            width: importScroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        importText.textContainer?.widthTracksTextView = true
        importScroll.documentView = importText
        importScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        return importScroll
    }

}
extension EqualizerPanelController {
    @objc private func gainChanged(_ slider: NSSlider) {
        var gains = profile.bandGains
        gains[slider.tag] = slider.doubleValue
        gainValueFields[slider.tag].stringValue = Self.gainLabel(slider.doubleValue)
        profile = EqualizerProfile(
            deviceUID: profile.deviceUID,
            preamp: profile.preamp,
            isBypassed: false,
            bandGains: gains
        )
        bypassButton.state = .off
        curveView.profile = profile
        onChange?(profile)
    }

    @objc private func preampChanged() {
        profile = EqualizerProfile(
            deviceUID: profile.deviceUID,
            preamp: preampSlider.doubleValue,
            isBypassed: profile.isBypassed,
            bandGains: profile.bandGains
        )
        preampSlider.doubleValue = profile.preamp
        preampValueField.stringValue = Self.gainLabel(profile.preamp)
        curveView.profile = profile
        onChange?(profile)
    }

    @objc private func bypassChanged() {
        profile = EqualizerProfile(
            deviceUID: profile.deviceUID,
            preamp: profile.preamp,
            isBypassed: bypassButton.state == .on,
            bandGains: profile.bandGains
        )
        curveView.profile = profile
        onChange?(profile)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyDBField(field)
    }

    @objc private func applyImport() {
        do {
            profile = try profile.applyingImportedBands(importText.string)
            syncControls()
            statusLabel.stringValue = "Imported"
            onChange?(profile)
        } catch EqualizerImportError.invalidLine(let line) {
            statusLabel.stringValue = "Invalid import line \(line)"
        } catch {
            statusLabel.stringValue = "Invalid import"
        }
    }

    @objc private func resetFlat() {
        profile = .flat(deviceUID: profile.deviceUID)
        syncControls()
        statusLabel.stringValue = "Reset flat"
        onChange?(profile)
    }

    func setProfile(_ profile: EqualizerProfile, outputDeviceName: String? = nil) {
        if let outputDeviceName {
            self.outputDeviceName = outputDeviceName
        }
        guard self.profile != profile else { return }
        self.profile = profile
        syncControls()
    }

    func setReplayGainDetails(
        track: Track?,
        data: ReplayGainNormalizationData?,
        mode: ReplayGainMode,
        playbackGainDB: Double?,
        cacheError: String?
    ) {
        replayGainDetailView.set(
            track: track,
            data: data,
            mode: mode,
            playbackGainDB: playbackGainDB,
            cacheError: cacheError
        )
    }

    private func syncInfoLabels() {
        outputDeviceLabel.stringValue = "Output device: \(outputDeviceName)"
        equalizerLabel.stringValue = "Equalizer: 31-band (\(profile.isBypassed ? "Bypassed" : "Enabled"))"
    }

    private func syncControls() {
        preampSlider.doubleValue = profile.preamp
        preampValueField.stringValue = Self.gainLabel(profile.preamp)
        bypassButton.state = profile.isBypassed ? .on : .off
        for (index, slider) in gainSliders.enumerated() {
            slider.doubleValue = profile.bandGains[index]
            gainValueFields[index].stringValue = Self.gainLabel(profile.bandGains[index])
        }
        curveView.profile = profile
    }

    private func configureDBField(_ field: NSTextField, tag: Int) {
        field.tag = tag
        field.delegate = self
        field.target = self
        field.action = #selector(dbFieldChanged(_:))
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = AppTheme.primaryText
        field.backgroundColor = AppTheme.raised
        field.isBezeled = true
        field.isEditable = true
        field.alignment = .right
    }

    @objc private func dbFieldChanged(_ field: NSTextField) {
        applyDBField(field)
    }

    private func applyDBField(_ field: NSTextField) {
        guard let value = Self.parseGain(field.stringValue) else {
            let fallback = field.tag == -1
                ? Self.gainLabel(profile.preamp)
                : Self.gainLabel(profile.bandGains[field.tag])
            field.stringValue = fallback
            return
        }

        if field.tag == -1 {
            profile = EqualizerProfile(
                deviceUID: profile.deviceUID,
                preamp: value,
                isBypassed: profile.isBypassed,
                bandGains: profile.bandGains
            )
            preampSlider.doubleValue = profile.preamp
            preampValueField.stringValue = Self.gainLabel(profile.preamp)
        } else if gainSliders.indices.contains(field.tag) {
            var gains = profile.bandGains
            gains[field.tag] = value
            profile = EqualizerProfile(
                deviceUID: profile.deviceUID,
                preamp: profile.preamp,
                isBypassed: false,
                bandGains: gains
            )
            gainSliders[field.tag].doubleValue = profile.bandGains[field.tag]
            gainValueFields[field.tag].stringValue = Self.gainLabel(profile.bandGains[field.tag])
            bypassButton.state = .off
        }

        curveView.profile = profile
        onChange?(profile)
    }

    private static func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return "\(String(format: "%g", frequency / 1_000))k Hz"
        }
        return "\(String(format: "%g", frequency)) Hz"
    }

    private static func gainLabel(_ gain: Double) -> String {
        String(format: "%+.1f", gain)
    }

    private static func parseGain(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(
            of: "dB",
            with: "",
            options: .caseInsensitive
        )
        return Double(normalized.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

final class EditingTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let shortcut = TextEditingShortcut(event: event, controlPolicy: .none) else {
            return super.performKeyEquivalent(with: event)
        }
        shortcut.perform(on: self)
        return true
    }
}
