import AppKit
import WavebookCore

@MainActor
final class SkipSegmentRowsView: NSObject {
    let scrollView = NSScrollView()
    var onRemove: ((Int) -> Void)?

    private let stack = NSStackView()

    override init() {
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.required, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    func activateConstraints() {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    func setSegments(_ segments: [AudioSkipSegment], canEdit: Bool) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !segments.isEmpty else {
            let label = NSTextField(labelWithString: "No saved segments")
            label.font = .systemFont(ofSize: 11)
            label.textColor = AppTheme.secondaryText
            stack.addArrangedSubview(label)
            return
        }
        for (index, segment) in segments.enumerated() {
            let start = PlaybackTimecode.string(from: segment.startTime)
            let end = PlaybackTimecode.string(from: segment.endTime)
            let label = NSTextField(labelWithString: "\(start)–\(end)")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = AppTheme.primaryText
            let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeRow(_:)))
            removeButton.bezelStyle = .rounded
            removeButton.contentTintColor = AppTheme.secondaryText
            removeButton.tag = index
            removeButton.isEnabled = canEdit
            removeButton.setAccessibilityLabel("Remove Skip Segment")
            let row = NSStackView(views: [label, removeButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
    }

    @objc private func removeRow(_ sender: NSButton) {
        onRemove?(sender.tag)
    }
}
