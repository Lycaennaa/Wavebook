import AppKit
import UniformTypeIdentifiers
import WavebookCore

final class RootSplitViewController: NSViewController {
    private let sidebarController = SidebarViewController()
    private let mainController: MainViewController
    private enum OnboardingStep {
        case welcome(OnboardingWelcomeViewController)
        case folders(OnboardingFoldersViewController)
        case personalization(OnboardingPersonalizationViewController)

        var viewController: NSViewController {
            switch self {
            case let .welcome(controller): controller
            case let .folders(controller): controller
            case let .personalization(controller): controller
            }
        }
    }

    private var onboardingStep: OnboardingStep?
    private var onboardingCopy = OnboardingCopy.bundled()
#if DEBUG
    private static let onboardingCopyPathKey = "Wavebook.debugOnboardingCopyPath"
#endif

    init(searchField: NSSearchField) {
        mainController = MainViewController(searchField: searchField)
        super.init(nibName: nil, bundle: nil)
#if DEBUG
        loadSavedOnboardingCopy()
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        sidebarController.onSelectPlaylist = { [weak self] destination in
            guard let self else { return }
            self.mainController.clearSearch()
            self.sidebarController.selectPlaylist(destination)
            self.mainController.navigation.show(destination: .playlist(destination), recordHistory: true)
        }
        mainController.onPlaylistCatalogChanged = { [weak self] playlists in
            self?.sidebarController.setPlaylists(playlists)
        }

        mainController.onOnboardingRequested = { [weak self] in
            self?.showOnboarding()
        }
        mainController.onLibraryScanStateChanged = { [weak self] snapshot in
            guard let self, case let .folders(controller) = self.onboardingStep else { return }
            controller.updateScanState(snapshot)
        }
        sidebarController.onRenamePlaylist = { [weak self] id in
            self?.mainController.beginRenamePlaylist(id: id)
        }
        sidebarController.onDeletePlaylist = { [weak self] id in
            self?.mainController.beginDeletePlaylist(id: id)
        }
        sidebarController.onSelect = { [weak self] page in
            self?.mainController.showPage(page)
            if page != .settings {
                self?.sidebarController.select(page)
            }
        }
        mainController.onPageChanged = { [weak self] page in
            guard let self, page != .search, page != .settings else { return }
            if page == .playlists,
               case let .playlist(destination) = self.mainController.navigation.currentDestination {
                self.sidebarController.selectPlaylist(destination)
            } else {
                self.sidebarController.select(page)
            }
        }

        addChild(sidebarController)
        addChild(mainController)

        view = RootSplitView(sidebar: sidebarController.view, main: mainController.view)
    }

    func handleMediaKey(_ command: MediaKeyCommand) -> Bool {
        mainController.handleMediaKey(command)
    }

    func addRoot() {
        mainController.addRoot()
    }

    func showSettings() {
        mainController.showSettings()
    }

    func showOnboarding() {
        if onboardingStep == nil { showOnboardingWelcome() }
        view.window?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWelcome() {
        let controller = OnboardingWelcomeViewController(
            copy: onboardingCopy,
            onChooseFolders: { [weak self] in self?.showOnboardingFolders() },
            onExit: { [weak self] in self?.showLibrary() }
        )
        displayOnboardingStep(.welcome(controller))
    }

    private func showOnboardingFolders() {
        guard onboardingStep != nil else { return }
        let controller = OnboardingFoldersViewController(
            folderActions: mainController.libraryFolderSettingsActions,
            scanSnapshot: mainController.libraryScan.snapshot,
            onBack: { [weak self] in self?.showOnboardingWelcome() },
            onContinue: { [weak self] in self?.showOnboardingPersonalization() },
            onOpenLibrary: { [weak self] in self?.showLibrary() }
        )
        displayOnboardingStep(.folders(controller))
    }

    private func showOnboardingPersonalization() {
        guard onboardingStep != nil else { return }
        let controller = OnboardingPersonalizationViewController(
            appearance: AppTheme.appearance,
            replayGainMode: mainController.playbackSession.replayGain.mode,
            skipSilentSegments: mainController.playbackSession.transport.skipSilentSegments,
            onAppearanceChanged: { AppTheme.apply($0) },
            onReplayGainModeChanged: { [weak self] mode in
                guard let self else { return false }
                return self.mainController.playbackSession.replayGain.setMode(mode)
            },
            onSkipSilentSegmentsChanged: { [weak self] enabled in
                guard let self else { return false }
                return self.mainController.playbackSession.transport.setSkipSilentSegments(enabled)
            },
            onOpenEqualizer: { [weak self] in self?.mainController.showEqualizer() },
            onBack: { [weak self] in self?.showOnboardingFolders() },
            onReturnToLibrary: { [weak self] in self?.showLibrary() }
        )
        displayOnboardingStep(.personalization(controller))
    }

    private func displayOnboardingStep(_ step: OnboardingStep) {
        if let onboardingStep {
            let currentController = onboardingStep.viewController
            currentController.view.removeFromSuperview()
            currentController.removeFromParent()
        }
        let controller = step.viewController
        addChild(controller)
        onboardingStep = step
        let onboardingView = controller.view
        onboardingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(onboardingView)
        NSLayoutConstraint.activate([
            onboardingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            onboardingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            onboardingView.topAnchor.constraint(equalTo: view.topAnchor),
            onboardingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func showLibrary() {
        guard let onboardingStep else { return }
        let controller = onboardingStep.viewController
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        self.onboardingStep = nil
    }
#if DEBUG
    func chooseOnboardingCopyFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Load Copy"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadOnboardingCopy(from: url)
        }
    }

    func reloadOnboardingCopy() {
        guard let path = UserDefaults.standard.string(forKey: Self.onboardingCopyPathKey),
              FileManager.default.fileExists(atPath: path) else {
            chooseOnboardingCopyFile()
            return
        }
        loadOnboardingCopy(from: URL(fileURLWithPath: path))
    }

    private func loadSavedOnboardingCopy() {
        guard let path = UserDefaults.standard.string(forKey: Self.onboardingCopyPathKey),
              let copy = try? OnboardingCopy.load(from: URL(fileURLWithPath: path)) else { return }
        onboardingCopy = copy
    }

    private func loadOnboardingCopy(from url: URL) {
        do {
            let copy = try OnboardingCopy.load(from: url)
            onboardingCopy = copy
            UserDefaults.standard.set(url.path, forKey: Self.onboardingCopyPathKey)
            if case let .welcome(controller) = onboardingStep {
                controller.update(copy: copy)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not load onboarding copy"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
#endif

    func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        mainController.finalizeForTermination(completion: completion)
    }

}
