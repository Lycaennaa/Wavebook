import AppKit
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

    init(searchField: NSSearchField) {
        mainController = MainViewController(searchField: searchField)
        super.init(nibName: nil, bundle: nil)
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

    func handleMediaKey(
        _ command: MediaKeyCommand,
        at timestamp: TimeInterval? = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        mainController.handleMediaKey(command, at: timestamp)
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
            autoContinuePlaybackAfterOutputChange:
                mainController.playbackSession.transport.autoContinuePlaybackAfterOutputChange,
            onAppearanceChanged: { AppTheme.apply($0) },
            onReplayGainModeChanged: { [weak self] mode in
                guard let self else { return false }
                return self.mainController.playbackSession.replayGain.setMode(mode)
            },
            onSkipSilentSegmentsChanged: { [weak self] enabled in
                guard let self else { return false }
                return self.mainController.playbackSession.transport.setSkipSilentSegments(enabled)
            },
            onAutoContinuePlaybackAfterOutputChange: { [weak self] enabled in
                guard let self else { return false }
                return self.mainController.playbackSession.transport.setAutoContinuePlaybackAfterOutputChange(enabled)
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

    func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        mainController.finalizeForTermination(completion: completion)
    }

}
