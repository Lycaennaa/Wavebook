import AppKit
import OSLog

private struct OperationalError: Equatable, Sendable {
    let kind: OperationalErrorKind
    let message: String
}

@MainActor
final class ApplicationNotificationCoordinator: NSObject {
    private let logger: Logger
    private let persistenceBanner = NSTextField(wrappingLabelWithString: "")
    private let operationErrorBanner = NSTextField(wrappingLabelWithString: "")
    private let operationErrorStack = NSStackView()
    private let dismissButton = NSButton(
        image: NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss operation errors"
        ) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let notificationStack = NSStackView()
    private var contentTopConstraint: NSLayoutConstraint?
    private var bannerConstraints: [NSLayoutConstraint] = []
    private var isTearingDown = false
    private var pendingErrors: [OperationalError] = []
    private var displayedErrors: [OperationalError] = []
    private var presentationScheduled = false
    private var expirationTimer: Timer?
    private var expirationID: UUID?

    init(logger: Logger) {
        self.logger = logger
        super.init()
        configureViews()
    }

    func install(in root: NSView, below topBar: NSView, above contentHost: NSView) {
        if let contentTopConstraint {
            NSLayoutConstraint.deactivate([contentTopConstraint])
        }
        NSLayoutConstraint.deactivate(bannerConstraints)
        notificationStack.removeFromSuperview()
        root.addSubview(notificationStack)

        let contentTopConstraint = contentHost.topAnchor.constraint(
            equalTo: topBar.bottomAnchor,
            constant: 14
        )
        self.contentTopConstraint = contentTopConstraint
        bannerConstraints = [
            notificationStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            notificationStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            notificationStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentHost.topAnchor.constraint(equalTo: notificationStack.bottomAnchor, constant: 8)
        ]
        NSLayoutConstraint.activate([contentTopConstraint])
        updateLayout()
    }

    func viewDidAppear() {
        isTearingDown = false
        flushPendingErrors()
    }

    func viewWillDisappear() {
        prepareForTermination()
    }

    func prepareForTermination() {
        isTearingDown = true
        pendingErrors.removeAll()
    }

    func cancelTermination() {
        isTearingDown = false
    }

    func report(
        _ error: Error,
        message: String,
        kind: OperationalErrorKind = .general
    ) {
        let detail = error.localizedDescription
        logger.error("\(message, privacy: .public): \(detail, privacy: .public)")
        let userMessage = detail.isEmpty ? message : "\(message): \(detail)"
        let error = OperationalError(kind: kind, message: userMessage)
        DispatchQueue.main.async { [weak self] in
            self?.queueOrPresent(error)
        }
    }

    func present(_ message: String, kind: OperationalErrorKind = .general) {
        queueOrPresent(OperationalError(kind: kind, message: message))
    }

    func clearOperationalErrors(for kind: OperationalErrorKind) {
        let hadPendingErrors = pendingErrors.contains { $0.kind == kind }
        let hadDisplayedErrors = displayedErrors.contains { $0.kind == kind }
        guard hadPendingErrors || hadDisplayedErrors else { return }
        pendingErrors.removeAll { $0.kind == kind }
        displayedErrors.removeAll { $0.kind == kind }
        renderOperationalErrors()
    }

    func showPersistenceError(_ message: String) {
        persistenceBanner.stringValue = message
        persistenceBanner.isHidden = false
        updateLayout()
    }

    func hidePersistenceError() {
        guard !persistenceBanner.isHidden else { return }
        persistenceBanner.isHidden = true
        updateLayout()
    }

    private func configureViews() {
        persistenceBanner.textColor = .systemRed
        persistenceBanner.font = .systemFont(ofSize: 12)
        persistenceBanner.isEditable = false
        persistenceBanner.translatesAutoresizingMaskIntoConstraints = false
        persistenceBanner.isHidden = true

        operationErrorBanner.textColor = .systemRed
        operationErrorBanner.font = .systemFont(ofSize: 12)
        operationErrorBanner.isEditable = false
        operationErrorBanner.translatesAutoresizingMaskIntoConstraints = false
        operationErrorBanner.isHidden = true
        operationErrorBanner.setContentHuggingPriority(.defaultLow, for: .horizontal)
        operationErrorBanner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        operationErrorStack.orientation = .horizontal
        operationErrorStack.alignment = .centerY
        operationErrorStack.spacing = 8
        operationErrorStack.translatesAutoresizingMaskIntoConstraints = false
        operationErrorStack.isHidden = true

        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.toolTip = "Dismiss operation errors"
        dismissButton.target = self
        dismissButton.action = #selector(dismissOperationalErrors)
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        operationErrorStack.addArrangedSubview(operationErrorBanner)
        operationErrorStack.addArrangedSubview(dismissButton)

        notificationStack.orientation = .vertical
        notificationStack.alignment = .width
        notificationStack.spacing = 8
        notificationStack.detachesHiddenViews = true
        notificationStack.translatesAutoresizingMaskIntoConstraints = false
        notificationStack.addArrangedSubview(persistenceBanner)
        notificationStack.addArrangedSubview(operationErrorStack)
    }

    private func queueOrPresent(_ error: OperationalError) {
        guard !isTearingDown else { return }
        guard hasUsableWindow else {
            guard !pendingErrors.contains(where: { $0.message == error.message }),
                  !displayedErrors.contains(where: { $0.message == error.message }) else { return }
            append(error, into: &pendingErrors)
            schedulePendingPresentation()
            return
        }
        present(error)
    }

    private func flushPendingErrors() {
        guard !isTearingDown else { return }
        guard hasUsableWindow else {
            schedulePendingPresentation()
            return
        }
        let errors = pendingErrors
        pendingErrors.removeAll()
        for error in errors {
            present(error)
        }
    }

    private var hasUsableWindow: Bool {
        guard !isTearingDown,
              let window = notificationStack.window,
              window.contentView != nil else { return false }
        return window.isVisible
    }

    private func schedulePendingPresentation() {
        guard !pendingErrors.isEmpty, !presentationScheduled else { return }
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.flushPendingErrors()
        }
    }

    @discardableResult
    private func append(_ error: OperationalError, into errors: inout [OperationalError]) -> Bool {
        guard !errors.contains(where: { $0.message == error.message }) else { return false }
        errors.append(error)
        if errors.count > 3 {
            errors.removeFirst()
        }
        return true
    }

    private func present(_ error: OperationalError) {
        guard !displayedErrors.contains(where: { $0.message == error.message }) else { return }
        guard append(error, into: &displayedErrors) else { return }
        renderOperationalErrors()
    }

    private func renderOperationalErrors() {
        let hasErrors = !displayedErrors.isEmpty
        operationErrorBanner.stringValue = displayedErrors.map(\.message).joined(separator: "\n")
        operationErrorBanner.isHidden = !hasErrors
        operationErrorStack.isHidden = !hasErrors
        dismissButton.isHidden = !hasErrors
        if hasErrors {
            scheduleExpiration()
        } else {
            cancelExpiration()
        }
        updateLayout()
    }

    private func updateLayout() {
        guard let contentTopConstraint, !bannerConstraints.isEmpty else { return }
        let hasVisibleBanner = !persistenceBanner.isHidden || !operationErrorStack.isHidden
        if hasVisibleBanner {
            NSLayoutConstraint.deactivate([contentTopConstraint])
            NSLayoutConstraint.activate(bannerConstraints)
        } else {
            NSLayoutConstraint.deactivate(bannerConstraints)
            NSLayoutConstraint.activate([contentTopConstraint])
        }
    }

    @objc private func dismissOperationalErrors() {
        clearAllOperationalErrors()
    }

    private func clearAllOperationalErrors() {
        pendingErrors.removeAll()
        displayedErrors.removeAll()
        renderOperationalErrors()
    }

    private func scheduleExpiration() {
        expirationTimer?.invalidate()
        let expirationID = UUID()
        self.expirationID = expirationID
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.expirationID == expirationID else { return }
                self.expirationTimer = nil
                self.expirationID = nil
                self.clearAllOperationalErrors()
            }
        }
    }

    private func cancelExpiration() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        expirationID = nil
    }
}
