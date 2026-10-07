import AppKit

@MainActor
final class OnboardingFoldersViewController: NSViewController {
  private let folderActions: LibraryFolderSettingsActions
  private let onOpenLibrary: () -> Void
  private let onBack: () -> Void
  private let onContinue: () -> Void
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
  private let backButton = NSButton(title: "Back", target: nil, action: nil)
  private let continueButton = NSButton(title: "Continue", target: nil, action: nil)

  init(
    folderActions: LibraryFolderSettingsActions,
    scanSnapshot: LibraryScanSnapshot,
    onBack: @escaping () -> Void,
    onContinue: @escaping () -> Void,
    onOpenLibrary: @escaping () -> Void
  ) {
    self.folderActions = folderActions
    self.scanSnapshot = scanSnapshot
    self.onBack = onBack
    self.onContinue = onContinue
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
    scanStatusLabel.font = .systemFont(ofSize: 14, weight: .medium)
    scanStatusLabel.textColor = AppTheme.primaryText
    scanStatusLabel.maximumNumberOfLines = 0
    scanStatusLabel.setAccessibilityLabel("Library scan status and matched lyric tracks")
    scanStatusLabel.setAccessibilityHelp("Reports scan status and counts tracks matched to local lyric files.")
    scanIndicator.style = .spinning
    scanIndicator.isIndeterminate = true
    scanIndicator.controlSize = .small
    scanIndicator.setAccessibilityLabel("Library scan progress")

    backButton.target = self
    backButton.action = #selector(goBack)
    backButton.bezelStyle = .rounded
    continueButton.target = self
    continueButton.action = #selector(continueOnboarding)
    continueButton.bezelStyle = .rounded
    continueButton.keyEquivalent = "\r"
    openLibraryButton.target = self
    openLibraryButton.action = #selector(openLibrary)
    openLibraryButton.bezelStyle = .rounded
    foldersView.configure(folderActions)
    let scanStatus = NSStackView(views: [scanIndicator, scanStatusLabel])
    scanStatus.orientation = .horizontal
    scanStatus.alignment = .centerY
    scanStatus.spacing = 8
    let navigation = NSStackView(views: [backButton, continueButton, openLibraryButton])
    navigation.orientation = .horizontal
    navigation.alignment = .centerY
    navigation.spacing = 10
    let content = NSStackView(views: [
      titleLabel, descriptionLabel, scanStatus, foldersView, navigation
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
    let previousStatus = scanStatusLabel.stringValue
    scanStatusLabel.stringValue =
      "\(scanStatusDescription(for: snapshot))\n\(matchedLyricsDescription(for: snapshot))"
    updateScanIndicator()
    if scanStatusLabel.stringValue != previousStatus,
       !snapshot.isScanning || snapshot.progress == nil {
      NSAccessibility.post(element: scanStatusLabel, notification: .valueChanged)
    }
  }

  private func scanStatusDescription(for snapshot: LibraryScanSnapshot) -> String {
    if snapshot.isScanning {
      guard let progress = snapshot.progress else {
        return "Scanning selected folders. You can open the library while scanning continues."
      }
      return progressDescription(progress)
    }
    if let failure = snapshot.failure {
      let folderName = folderName(for: failure.root)
      return "Could not add or scan \(folderName). Any previously indexed music was kept. "
        + "Add another folder or open the library."
    }
    guard let progress = snapshot.progress else {
      return hasObservedScan
        ? "No scan is active. Select a folder to scan, or open the library."
        : "Add one or more folders to start scanning, or open the library without folders."
    }
    return completedScanDescription(progress)
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

  private func completedScanDescription(_ progress: LibraryRootScanProgress) -> String {
    let folderName = folderName(for: progress.root)
    if progress.totalFileCount == 0 {
      return "No supported audio files found in \(folderName). Add another folder with music."
    }
    if progress.completedFileCount == progress.totalFileCount {
      return "Scanned \(fileCountDescription(progress.totalFileCount, singularFileType: "audio file")) "
        + "in \(folderName). Add another folder if the library is still empty."
    }
    return "Scan stopped after \(progress.completedFileCount.formatted()) of "
      + "\(fileCountDescription(progress.totalFileCount, singularFileType: "audio file")) in \(folderName)."
  }
  private func progressDescription(_ progress: LibraryRootScanProgress) -> String {
    let folderName = folderName(for: progress.root)
    return "\(folderName): Scanned \(progress.completedFileCount.formatted()) of "
      + "\(fileCountDescription(progress.totalFileCount, singularFileType: "audio file"))."
  }
  private func fileCountDescription(_ count: Int, singularFileType: String) -> String {
    let fileType = count == 1 ? singularFileType : "\(singularFileType)s"
    return "\(count.formatted()) \(fileType)"
  }
  private func matchedLyricsDescription(for snapshot: LibraryScanSnapshot) -> String {
    if snapshot.isScanning {
      if let completed = snapshot.lastCompletedMatchedLyricsCount {
        return matchedLyricsDescription(for: completed.root, count: completed.matchedLyricTrackCount)
      }
      guard let progress = snapshot.progress else { return "Matching lyric tracks after folder discovery…" }
      let folderName = folderName(for: progress.root)
      guard let count = progress.matchedLyricTrackCount else { return "Matching lyric tracks in \(folderName)…" }
      return matchedLyricsDescription(for: progress.root, count: count)
    }
    if let failure = snapshot.failure {
      return "Tracks with matched lyrics in \(folderName(for: failure.root)): unavailable"
    }
    if let completed = snapshot.lastCompletedMatchedLyricsCount {
      return matchedLyricsDescription(for: completed.root, count: completed.matchedLyricTrackCount)
    }
    guard let progress = snapshot.progress else {
      guard let roots = folderActions.roots() else { return "Matched lyric tracks: unavailable" }
      return roots.isEmpty
        ? "Matched lyric tracks: 0"
        : "Matched lyric tracks: scan a folder to count."
    }
    return matchedLyricsDescription(for: progress.root, count: progress.matchedLyricTrackCount)
  }

  private func matchedLyricsDescription(for root: URL, count: Int?) -> String {
    guard let count else { return "Tracks with matched lyrics in \(folderName(for: root)): unavailable" }
    return "Tracks with matched lyrics in \(folderName(for: root)): \(count.formatted())"
  }

  private func folderName(for root: URL) -> String {
    root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
  }

  @objc private func goBack() {
    onBack()
  }

  @objc private func continueOnboarding() {
    onContinue()
  }

  @objc private func openLibrary() {
    onOpenLibrary()
  }
}
