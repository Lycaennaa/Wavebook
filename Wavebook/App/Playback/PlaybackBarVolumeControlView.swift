import AppKit
import WavebookCore

final class PlaybackBarVolumeControlView: ThemeAwareView, NSTextFieldDelegate {
    var onVolumeChanged: ((Float) -> Void)?

    private let volumeLabel = NSTextField(labelWithString: "Vol")
    private let volumeSlider = NSSlider(
        value: Double(PlaybackVolume.newInstallDefault),
        minValue: 0,
        maxValue: Double(PlaybackVolume.maximum),
        target: nil,
        action: nil
    )
    private let volumeField = NSTextField(
        string: "\(Int((PlaybackVolume.newInstallDefault * 100).rounded()))%"
    )
    private let volumeStepper = NSStepper()
    private let volumeStack = NSStackView()

    override var intrinsicContentSize: NSSize {
        volumeStack.fittingSize
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
        configureLayout()
        updateThemeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateThemeAppearance()
    }

    func setVolume(_ volume: Float) {
        let normalizedVolume = PlaybackVolume.normalized(Double(volume))
        volumeSlider.doubleValue = normalizedVolume
        volumeStepper.doubleValue = (normalizedVolume * 100).rounded()
        volumeField.stringValue = "\(Int((normalizedVolume * 100).rounded()))%"
    }

    private func configureControls() {
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.setAccessibilityLabel("Output Device Volume")
        volumeSlider.toolTip = "Adjust volume for the current output device"
        volumeSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true

        volumeField.isEditable = true
        volumeField.isSelectable = true
        volumeField.isBordered = false
        volumeField.drawsBackground = false
        volumeField.alignment = .center
        volumeField.controlSize = .small
        volumeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeField.delegate = self
        volumeField.wantsLayer = true
        volumeField.layer?.cornerRadius = 5
        volumeField.layer?.borderWidth = 1
        volumeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        volumeField.setAccessibilityLabel("Output Device Volume Percentage")
        volumeField.toolTip = "Enter volume or use the up/down arrows (0 to 200%; above 100% may clip)"

        volumeStepper.minValue = 0
        volumeStepper.maxValue = Double(PlaybackVolume.maximum) * 100
        volumeStepper.increment = 1
        volumeStepper.valueWraps = false
        volumeStepper.controlSize = .small
        volumeStepper.doubleValue = Double(PlaybackVolume.newInstallDefault) * 100
        volumeStepper.target = self
        volumeStepper.action = #selector(volumeStepperChanged)
        volumeStepper.setAccessibilityLabel("Output Device Volume Stepper")
        volumeStepper.toolTip = "Adjust volume by 1%"
    }

    private func configureLayout() {
        let inputStack = NSStackView(views: [volumeField, volumeStepper])
        inputStack.orientation = .horizontal
        inputStack.alignment = .centerY
        inputStack.spacing = 2
        volumeStack.orientation = .horizontal
        volumeStack.alignment = .centerY
        volumeStack.spacing = 8
        volumeStack.addArrangedSubview(volumeLabel)
        volumeStack.addArrangedSubview(volumeSlider)
        volumeStack.addArrangedSubview(inputStack)
        volumeStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(volumeStack)
        NSLayoutConstraint.activate([
            volumeStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumeStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumeStack.topAnchor.constraint(equalTo: topAnchor),
            volumeStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateThemeAppearance() {
        volumeLabel.textColor = AppTheme.secondaryText
        volumeField.textColor = AppTheme.primaryText
        volumeField.layer?.backgroundColor = AppTheme.cgColor(AppTheme.raised, in: volumeField)
        volumeField.layer?.borderColor = AppTheme.cgColor(AppTheme.border, in: volumeField)
    }

    @objc private func volumeSliderChanged() {
        let volume = Float(volumeSlider.doubleValue)
        setVolume(volume)
        onVolumeChanged?(volume)
    }

    @objc private func volumeStepperChanged() {
        setVolumePercentage(volumeStepper.doubleValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === volumeField else { return }
        guard let percentage = volumePercentage(from: field.stringValue) else {
            setVolume(Float(volumeSlider.doubleValue))
            return
        }
        setVolumePercentage(percentage)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === volumeField else { return false }
        let change: Double
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            change = 1
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            change = -1
        } else {
            return false
        }

        let currentPercentage = volumePercentage(from: textView.string) ?? volumeStepper.doubleValue
        setVolumePercentage(currentPercentage + change)
        textView.string = volumeField.stringValue
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return true
    }

    private func volumePercentage(from text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let percentageText = value.hasSuffix("%")
            ? String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : value
        guard let percentage = Double(percentageText), percentage.isFinite else { return nil }
        return PlaybackVolume.normalized(percentage / 100) * 100
    }

    private func setVolumePercentage(_ percentage: Double) {
        let volume = Float(PlaybackVolume.normalized(percentage / 100))
        setVolume(volume)
        onVolumeChanged?(volume)
    }
}
