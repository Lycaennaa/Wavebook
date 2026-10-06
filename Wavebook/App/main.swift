import AppKit
import MediaPlayer
import WavebookCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var remoteCommandTargets: [Any] = []
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Old versions persisted appearance on every launch; use that only to exclude existing installs once.
        let shouldShowWelcome = OnboardingLaunchPolicy.shouldShowWelcome(
            isLegacyInstall: { AppTheme.hasPersistedAppearance() }
        )
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        AppTheme.applySavedAppearance()

        let windowController = MainWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)
        if shouldShowWelcome {
            windowController.showOnboarding()
        }
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        registerRemoteCommands()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true

        let reply: @MainActor (Bool) -> Void = { [weak self] shouldTerminate in
            DispatchQueue.main.async {
                self?.terminationInProgress = false
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        if let windowController {
            windowController.prepareForTermination(completion: reply)
        } else {
            reply(true)
        }
        return .terminateLater
    }

    func handleMediaKey(_ command: MediaKeyCommand) -> Bool {
        windowController?.handleMediaKey(command) ?? false
    }

    @objc private func addLibraryFolder(_ sender: Any?) {
        windowController?.addRoot()
    }

    @objc private func showSettings(_ sender: Any?) {
        windowController?.showSettings()
    }

    @objc private func showOnboarding(_ sender: Any?) {
        windowController?.showOnboarding()
    }
#if DEBUG
    @objc private func chooseOnboardingCopyFile(_ sender: Any?) {
        windowController?.chooseOnboardingCopyFile()
    }

    @objc private func reloadOnboardingCopy(_ sender: Any?) {
        windowController?.reloadOnboardingCopy()
    }
#endif

    private func installMainMenu() {
        let mainMenu = NSMenu()
        for (title, submenu) in [
            ("Wavebook", makeApplicationMenu()),
            ("File", makeFileMenu()),
            ("Edit", makeEditMenu())
        ] {
            let item = NSMenuItem()
            item.title = title
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        let windowMenu = makeWindowMenu()
        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = "Window"
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        let helpMenu = makeHelpMenu()
        let helpMenuItem = NSMenuItem()
        helpMenuItem.title = "Help"
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    private func makeApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Wavebook")
        menu.addItem(NSMenuItem(
            title: "About Wavebook",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hide Wavebook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)
        menu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Wavebook",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    private func makeHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        let onboardingItem = NSMenuItem(
            title: "Welcome to Wavebook…",
            action: #selector(showOnboarding(_:)),
            keyEquivalent: ""
        )
        onboardingItem.target = self
#if DEBUG
        menu.addItem(.separator())
        let chooseCopyItem = NSMenuItem(
            title: "Choose Onboarding Copy File…",
            action: #selector(chooseOnboardingCopyFile(_:)),
            keyEquivalent: ""
        )
        chooseCopyItem.target = self
        menu.addItem(chooseCopyItem)
        let reloadCopyItem = NSMenuItem(
            title: "Reload Onboarding Copy",
            action: #selector(reloadOnboardingCopy(_:)),
            keyEquivalent: ""
        )
        reloadCopyItem.target = self
        menu.addItem(reloadCopyItem)
#endif
        menu.addItem(onboardingItem)
        return menu
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        let addFolderItem = NSMenuItem(
            title: "Add Library Folder…",
            action: #selector(addLibraryFolder(_:)),
            keyEquivalent: "o"
        )
        addFolderItem.target = self
        menu.addItem(addFolderItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        return menu
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        addEditMenuItem("Undo", action: #selector(undo(_:)), key: "z", target: self, to: menu)
        addEditMenuItem(
            "Redo",
            action: #selector(redo(_:)),
            key: "z",
            modifiers: [.command, .shift],
            target: self,
            to: menu
        )
        addEditMenuItem("Cut", action: #selector(NSText.cut(_:)), key: "x", to: menu)
        addEditMenuItem("Copy", action: #selector(NSText.copy(_:)), key: "c", to: menu)
        addEditMenuItem("Paste", action: #selector(NSText.paste(_:)), key: "v", to: menu)
        addEditMenuItem("Select All", action: #selector(NSResponder.selectAll(_:)), key: "a", to: menu)
        return menu
    }

    private func addEditMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    private func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        menu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    @objc private func undo(_ sender: Any?) {
        NSApp.keyWindow?.firstResponder?.undoManager?.undo()
    }

    @objc private func redo(_ sender: Any?) {
        NSApp.keyWindow?.firstResponder?.undoManager?.redo()
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        remoteCommandTargets = [
            center.playCommand.addTarget { [weak self] _ in
                self?.handleRemoteCommand(.play) ?? .noSuchContent
            },
            center.pauseCommand.addTarget { [weak self] _ in
                self?.handleRemoteCommand(.pause) ?? .noSuchContent
            },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.handleRemoteCommand(.togglePlayPause) ?? .noSuchContent
            },
            center.nextTrackCommand.addTarget { [weak self] _ in
                self?.handleRemoteCommand(.nextTrack) ?? .noSuchContent
            },
            center.previousTrackCommand.addTarget { [weak self] _ in
                self?.handleRemoteCommand(.previousTrack) ?? .noSuchContent
            }
        ]
    }

    private func handleRemoteCommand(_ command: MediaKeyCommand) -> MPRemoteCommandHandlerStatus {
        handleMediaKey(command) ? .success : .noSuchContent
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
