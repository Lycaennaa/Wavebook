import AppKit

@MainActor
final class OnboardingFoldersViewController: NSViewController {
  private let folderActions: LibraryFolderSettingsActions
  private let onOpenLibrary: () -> Void
  private var hasObservedScan = false
  private var scanSnapshot: LibraryScanSnapshot
  private let titleLabel = NSTextField(labelWithString: "Add your music folders")
  private let descriptionLabel = NSTextField(
    wrappingLabelWithString:
      "Wavebook scans selected folders in the background. You can open the library before scanning finishes."
  )
  private let scanStatusLabel = NSTextField(wrappingLabelWithString: "")
  private let scanIndicator = NSProgressIndicator()
  private let foldersView = LibraryFoldersSettingsView()
  private let openLibraryButton = NSButton(title: "Open Library", target: nil, action: nil)

  init(
    folderActions: LibraryFolderSettingsActions,
    scanSnapshot: LibraryScanSnapshot,
    onOpenLibrary: @escaping () -> Void
  ) {
    self.folderActions = folderActions
    self.scanSnapshot = scanSnapshot
    self.onOpenLibrary = onOpenLibrary
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let root = ThemeBackgroundView()
    titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
    titleLabel.textColor = AppTheme.primaryText
    descriptionLabel.font = .systemFont(ofSize: 14)
    descriptionLabel.textColor = AppTheme.secondaryText
    descriptionLabel.alignment = .center
    descriptionLabel.maximumNumberOfLines = 0
    descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true
    scanStatusLabel.font = .systemFont(ofSize: 12)
    scanStatusLabel.textColor = AppTheme.secondaryText
    scanStatusLabel.maximumNumberOfLines = 0
    scanIndicator.style = .spinning
    scanIndicator.isIndeterminate = true
    scanIndicator.controlSize = .small
    scanIndicator.setAccessibilityLabel("Library scan progress")

    openLibraryButton.target = self
    openLibraryButton.action = #selector(openLibrary)
    openLibraryButton.bezelStyle = .rounded
    openLibraryButton.keyEquivalent = "\r"

    foldersView.configure(folderActions)
    let scanStatus = NSStackView(views: [scanIndicator, scanStatusLabel])
    scanStatus.orientation = .horizontal
    scanStatus.alignment = .centerY
    scanStatus.spacing = 8
    let content = NSStackView(views: [
      titleLabel, descriptionLabel, scanStatus, foldersView, openLibraryButton
    ])
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 16
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
      content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
      content.widthAnchor.constraint(equalToConstant: 620),
      foldersView.widthAnchor.constraint(equalTo: content.widthAnchor),
      scanStatus.widthAnchor.constraint(equalTo: content.widthAnchor)
    ])
    view = root
    updateScanState(scanSnapshot)
  }

  func updateScanState(_ snapshot: LibraryScanSnapshot) {
    scanSnapshot = snapshot
    if snapshot.isScanning { hasObservedScan = true }
    guard isViewLoaded else { return }
    if snapshot.isScanning {
      if let progress = snapshot.progress {
        scanStatusLabel.stringValue = progressDescription(progress)
      } else {
        scanStatusLabel.stringValue = "Scanning selected folders. You can open the library while scanning continues."
      }
    } else if let failure = snapshot.failure {
      let folderName = folderName(for: failure.root)
      scanStatusLabel.stringValue =
        "Could not scan \(folderName). Indexed music was kept. "
          + "Add another folder or open the library."
    } else if let progress = snapshot.progress {
      let folderName = folderName(for: progress.root)
      if progress.totalFileCount == 0 {
        scanStatusLabel.stringValue =
          "No supported audio files found in \(folderName). "
            + "Add another folder with music."
      } else if progress.completedFileCount == progress.totalFileCount {
        scanStatusLabel.stringValue =
          "Scanned \(progress.totalFileCount.formatted()) audio files in \(folderName). "
            + "Add another folder if the library is still empty."
      } else {
        scanStatusLabel.stringValue =
          "Scan stopped after \(progress.completedFileCount.formatted()) of "
            + "\(progress.totalFileCount.formatted()) audio files in \(folderName)."
      }
    } else if hasObservedScan {
      scanStatusLabel.stringValue =
        "No scan is active. Select a folder to scan, or open the library."
    } else {
      scanStatusLabel.stringValue = "Add one or more folders to start scanning, or open the library without folders."
    }
    updateScanIndicator()
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    updateScanIndicator()
  }

  override func viewWillDisappear() {
    scanIndicator.stopAnimation(nil)
    scanIndicator.isHidden = true
    super.viewWillDisappear()
  }

  private func updateScanIndicator() {
    guard isViewLoaded else { return }
    let shouldAnimate = scanSnapshot.isScanning && view.window != nil
    scanIndicator.isHidden = !shouldAnimate
    if shouldAnimate {
      scanIndicator.startAnimation(nil)
    } else {
      scanIndicator.stopAnimation(nil)
    }
  }

  private func progressDescription(_ progress: LibraryRootScanProgress) -> String {
    let folderName = folderName(for: progress.root)
    return "\(folderName): Scanned \(progress.completedFileCount.formatted()) of "
      + "\(progress.totalFileCount.formatted()) audio files."
  }

  private func folderName(for root: URL) -> String {
    root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
  }

  @objc private func openLibrary() {
    onOpenLibrary()
  }
}
