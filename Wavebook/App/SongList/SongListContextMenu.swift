import AppKit
import UniformTypeIdentifiers
import WavebookCore

private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc @MainActor private func invoke() {
        handler()
    }

    func menuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invoke), keyEquivalent: "")
        item.target = self
        item.representedObject = self
        return item
    }
}

private final class AddApplicationMenuActionTarget: NSObject {
    private let onSelected: (URL) -> Void

    init(onSelected: @escaping (URL) -> Void) {
        self.onSelected = onSelected
        super.init()
    }

    @objc @MainActor private func invoke() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add App"
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        saveCustomApplication(applicationURL)
        onSelected(applicationURL)
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Add App…", action: #selector(invoke), keyEquivalent: "")
        item.target = self
        item.representedObject = self
        return item
    }
}

private func menuItem(title: String, handler: @escaping () -> Void) -> NSMenuItem {
    MenuActionTarget(handler: handler).menuItem(title: title)
}
private let customApplicationsDefaultsKey = "SongListContextMenu.customApplicationPaths"
private let browserContentTypes = [
    UTType.html,
    UTType.url,
    UTType.webArchive
]
private let allowedLyricsApplicationBundleIdentifiers: Set<String> = ["com.apple.TextEdit"]

private func applicationName(at url: URL) -> String {
    let bundle = Bundle(url: url)
    return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
}
private struct ApplicationMenuEntry {
    let url: URL
    let name: String

    var normalizedName: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private func customApplicationURLs() -> [URL] {
    let paths = UserDefaults.standard.stringArray(forKey: customApplicationsDefaultsKey) ?? []
    return paths
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

private func saveCustomApplication(_ url: URL) {
    let path = url.standardizedFileURL.path
    var paths = UserDefaults.standard.stringArray(forKey: customApplicationsDefaultsKey) ?? []
    guard !paths.contains(path) else { return }
    paths.append(path)
    UserDefaults.standard.set(paths, forKey: customApplicationsDefaultsKey)
}

private func browserApplicationPaths() -> Set<String> {
    browserContentTypes
        .flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
        .map(\.standardizedFileURL.path)
        .reduce(into: Set<String>()) { paths, path in
            paths.insert(path)
        }
}

private func applicationsToOpenFile(
    at url: URL? = nil,
    additionalContentTypes: [UTType] = [],
    excludeBrowserApplications: Bool = true,
    allowedApplicationBundleIdentifiers: Set<String> = []
) -> [ApplicationMenuEntry] {
    var contentTypes = additionalContentTypes
    if let url, let fileType = UTType(filenameExtension: url.pathExtension) {
        contentTypes.insert(fileType, at: 0)
    }
    let typedApplications = contentTypes.flatMap { type in
        NSWorkspace.shared.urlsForApplications(toOpen: type)
    }
    let browserPaths = excludeBrowserApplications ? browserApplicationPaths() : []
    let isExcludedApplication: (URL) -> Bool = { applicationURL in
        guard browserPaths.contains(applicationURL.standardizedFileURL.path) else { return false }
        let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        return !allowedApplicationBundleIdentifiers.contains(bundleIdentifier ?? "")
    }
    let fileApplications = url.map {
        NSWorkspace.shared.urlsForApplications(toOpen: $0)
            .filter { !isExcludedApplication($0) }
    } ?? []
    let applications = (typedApplications + fileApplications)
        .filter { !isExcludedApplication($0) }
        + customApplicationURLs()
    var seenPaths = Set<String>()
    return applications
        .compactMap { application in
            let path = application.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return nil }
            return ApplicationMenuEntry(url: application, name: applicationName(at: application))
        }
        .sorted { lhs, rhs in
            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            guard nameComparison == .orderedSame else {
                return nameComparison == .orderedAscending
            }
            return lhs.url.standardizedFileURL.path.localizedStandardCompare(
                rhs.url.standardizedFileURL.path
            ) == .orderedAscending
        }
}

private func applicationsToOpenMusicFile(at url: URL) -> [ApplicationMenuEntry] {
    applicationsToOpenFile(at: url, additionalContentTypes: [.audio])
}

private func applicationsToOpenLyricsFile() -> [ApplicationMenuEntry] {
    var contentTypes: [UTType] = [.text, .plainText]
    if let lrcType = UTType(filenameExtension: "lrc") {
        contentTypes.insert(lrcType, at: 0)
    }
    if let txtType = UTType(filenameExtension: "txt") {
        contentTypes.append(txtType)
    }
    return applicationsToOpenFile(
        additionalContentTypes: contentTypes,
        excludeBrowserApplications: true,
        allowedApplicationBundleIdentifiers: allowedLyricsApplicationBundleIdentifiers
    )
}

func openFile(_ fileURL: URL, with applicationURL: URL) {
    NSWorkspace.shared.open(
        [fileURL],
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
        guard let error else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Could Not Open File"
            alert.informativeText = "\(fileURL.lastPathComponent)\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

private func addApplicationMenuItem(onSelected: @escaping (URL) -> Void) -> NSMenuItem {
    AddApplicationMenuActionTarget(onSelected: onSelected).menuItem()
}
private func openInAppMenuItem(
    title: String,
    applications: [ApplicationMenuEntry],
    onOpen: @escaping (URL) -> Void
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: title)
    var nameCounts = [String: Int]()
    for application in applications {
        nameCounts[application.normalizedName, default: 0] += 1
    }
    for application in applications {
        let applicationTitle = nameCounts[application.normalizedName] == 1
            ? application.name
            : "\(application.name) (\(application.url.standardizedFileURL.path))"
        submenu.addItem(menuItem(title: applicationTitle) {
            onOpen(application.url)
        })
    }
    if !applications.isEmpty {
        submenu.addItem(.separator())
    }
    submenu.addItem(addApplicationMenuItem(onSelected: onOpen))
    item.submenu = submenu
    return item
}

private func openInAppMenuItem(contextTrack: Track) -> NSMenuItem {
    let url = URL(fileURLWithPath: contextTrack.path)
    return openInAppMenuItem(
        title: "Open in App",
        applications: applicationsToOpenMusicFile(at: url),
        onOpen: { openFile(url, with: $0) }
    )
}

private func navigationMenuItem(title: String, values: [String], handler: @escaping (String) -> Void) -> NSMenuItem {
    if values.count == 1 {
        return menuItem(title: title) { handler(values[0]) }
    }

    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: title)
    for value in values {
        submenu.addItem(menuItem(title: value) { handler(value) })
    }
    item.submenu = submenu
    return item
}
typealias LyricsFileAvailabilityObserver = (Track, @escaping (Bool) -> Void) -> Void

struct TrackContextMenuActions {
    let onAddToQueue: (([Track]) -> Void)?
    let onAddNextToQueue: (([Track]) -> Void)?
    let onDownloadLyrics: ((Track) -> Void)?
    let onOpenLyricsInApp: ((Track, URL) -> Void)?
    let onShowLyricsInFinder: ((Track) -> Void)?
    let lyricsFileAvailabilityProvider: ((Track) -> Bool?)?
    let lyricsFileAvailabilityObserver: LyricsFileAvailabilityObserver?
    let onManageSkipSegments: ((Track) -> Void)?
    let onAlbumSelect: ((AlbumKey) -> Void)?
    let onArtistSelect: ((String) -> Void)?
    let onGenreSelect: ((String) -> Void)?
    let onRescanLoudness: (([Track]) -> Void)?
    let onToggleFavorite: (([Track]) -> Void)?
    let manualPlaylists: [Playlist]
    let onAddToPlaylist: (([Track], Int64) -> Void)?
    init(
        onAddToQueue: (([Track]) -> Void)? = nil,
        onAddNextToQueue: (([Track]) -> Void)? = nil,
        onDownloadLyrics: ((Track) -> Void)? = nil,
        onOpenLyricsInApp: ((Track, URL) -> Void)? = nil,
        onShowLyricsInFinder: ((Track) -> Void)? = nil,
        lyricsFileAvailabilityProvider: ((Track) -> Bool?)? = nil,
        lyricsFileAvailabilityObserver: LyricsFileAvailabilityObserver? = nil,
        onManageSkipSegments: ((Track) -> Void)? = nil,
        onAlbumSelect: ((AlbumKey) -> Void)? = nil,
        onArtistSelect: ((String) -> Void)? = nil,
        onGenreSelect: ((String) -> Void)? = nil,
        onRescanLoudness: (([Track]) -> Void)? = nil,
        onToggleFavorite: (([Track]) -> Void)? = nil,
        manualPlaylists: [Playlist] = [],
        onAddToPlaylist: (([Track], Int64) -> Void)? = nil
    ) {
        self.onAddToQueue = onAddToQueue
        self.onAddNextToQueue = onAddNextToQueue
        self.onDownloadLyrics = onDownloadLyrics
        self.onOpenLyricsInApp = onOpenLyricsInApp
        self.onShowLyricsInFinder = onShowLyricsInFinder
        self.lyricsFileAvailabilityProvider = lyricsFileAvailabilityProvider
        self.lyricsFileAvailabilityObserver = lyricsFileAvailabilityObserver
        self.onManageSkipSegments = onManageSkipSegments
        self.onAlbumSelect = onAlbumSelect
        self.onArtistSelect = onArtistSelect
        self.onGenreSelect = onGenreSelect
        self.onRescanLoudness = onRescanLoudness
        self.onToggleFavorite = onToggleFavorite
        self.manualPlaylists = manualPlaylists
        self.onAddToPlaylist = onAddToPlaylist
    }
}
private func secondSectionItems(
    tracks: [Track],
    contextTrack: Track,
    actions: TrackContextMenuActions,
    lyricsFileAvailability: Bool?
) -> [NSMenuItem] {
    var submenuItems = [NSMenuItem]()
    var actionItems = [NSMenuItem]()

    actionItems.append(menuItem(title: "Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(tracks.map { URL(fileURLWithPath: $0.path) })
    })
    submenuItems.append(openInAppMenuItem(contextTrack: contextTrack))
    appendLyricsItems(
        to: &submenuItems,
        actions: &actionItems,
        contextTrack: contextTrack,
        menuActions: actions,
        availability: lyricsFileAvailability
    )
    appendPlaylistItem(to: &submenuItems, tracks: tracks, actions: actions)
    appendTrackActionItems(to: &actionItems, tracks: tracks, contextTrack: contextTrack, actions: actions)

    let sortedSubmenuItems = submenuItems.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    let sortedActionItems = actionItems.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    var items = sortedSubmenuItems
    if !sortedSubmenuItems.isEmpty, !sortedActionItems.isEmpty {
        items.append(.separator())
    }
    items.append(contentsOf: sortedActionItems)
    return items
}

private func appendLyricsItems(
    to submenuItems: inout [NSMenuItem],
    actions actionItems: inout [NSMenuItem],
    contextTrack: Track,
    menuActions: TrackContextMenuActions,
    availability: Bool?
) {
    if availability == nil {
        let item = menuItem(title: "Checking for LRC…") {}
        item.isEnabled = false
        actionItems.append(item)
    } else if availability == true {
        if let onOpenLyricsInApp = menuActions.onOpenLyricsInApp {
            submenuItems.append(
                openInAppMenuItem(
                    title: "Open LRC in App",
                    applications: applicationsToOpenLyricsFile(),
                    onOpen: { onOpenLyricsInApp(contextTrack, $0) }
                )
            )
        }
        if let onShowLyricsInFinder = menuActions.onShowLyricsInFinder {
            actionItems.append(menuItem(title: "Show LRC in Finder") {
                onShowLyricsInFinder(contextTrack)
            })
        }
    }
}

private func appendPlaylistItem(to items: inout [NSMenuItem], tracks: [Track], actions: TrackContextMenuActions) {
    guard let onAddToPlaylist = actions.onAddToPlaylist, !actions.manualPlaylists.isEmpty else { return }
    let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Add to Playlist")
    for playlist in actions.manualPlaylists {
        submenu.addItem(menuItem(title: playlist.name) { onAddToPlaylist(tracks, playlist.id) })
    }
    item.submenu = submenu
    items.append(item)
}

private func appendTrackActionItems(
    to items: inout [NSMenuItem],
    tracks: [Track],
    contextTrack: Track,
    actions: TrackContextMenuActions
) {
    if let onAddToQueue = actions.onAddToQueue {
        items.append(menuItem(title: "Add to Queue") { onAddToQueue(tracks) })
    }
    if let onAddNextToQueue = actions.onAddNextToQueue {
        items.append(menuItem(title: "Add Next in Queue") { onAddNextToQueue(tracks) })
    }
    if let onToggleFavorite = actions.onToggleFavorite {
        items.append(menuItem(title: "Favorite / Unfavorite") { onToggleFavorite(tracks) })
    }
    if let onRescanLoudness = actions.onRescanLoudness {
        items.append(menuItem(title: "Rescan Loudness") { onRescanLoudness(tracks) })
    }
    if let onDownloadLyrics = actions.onDownloadLyrics {
        items.append(menuItem(title: "Download Lyrics…") {
            onDownloadLyrics(contextTrack)
        })
    }
    if let onManageSkipSegments = actions.onManageSkipSegments {
        items.append(menuItem(title: "Manage Skip Segments") {
            onManageSkipSegments(contextTrack)
        })
    }
}
func makeTrackContextMenu(
    tracks: [Track],
    contextTrack: Track,
    actions: TrackContextMenuActions
) -> NSMenu {
    let menu = NSMenu()
    var hasNavigationItems = false
    if let onAlbumSelect = actions.onAlbumSelect {
        menu.addItem(menuItem(title: "Go to Album") { onAlbumSelect(contextTrack.albumKey) })
        hasNavigationItems = true
    }
    if let onArtistSelect = actions.onArtistSelect {
        let artists = contextTrack.artists.isEmpty ? [""] : contextTrack.artists
        menu.addItem(navigationMenuItem(title: "Go to Artist", values: artists, handler: onArtistSelect))
        hasNavigationItems = true
    }
    if let onGenreSelect = actions.onGenreSelect {
        let genres = contextTrack.genres.isEmpty ? [""] : contextTrack.genres
        menu.addItem(navigationMenuItem(title: "Go to Genre", values: genres, handler: onGenreSelect))
        hasNavigationItems = true
    }
    if hasNavigationItems {
        menu.addItem(.separator())
    }
    let lyricsFileAvailability: Bool?
    if let provider = actions.lyricsFileAvailabilityProvider {
        lyricsFileAvailability = provider(contextTrack)
    } else {
        lyricsFileAvailability = contextTrack.hasLyrics
    }
    let secondSectionStart = menu.numberOfItems
    for item in secondSectionItems(
        tracks: tracks,
        contextTrack: contextTrack,
        actions: actions,
        lyricsFileAvailability: lyricsFileAvailability
    ) {
        menu.addItem(item)
    }
    if lyricsFileAvailability == nil,
       let observer = actions.lyricsFileAvailabilityObserver {
        observer(contextTrack) { [weak menu] availability in
            guard let menu else { return }
            let items = secondSectionItems(
                tracks: tracks,
                contextTrack: contextTrack,
                actions: actions,
                lyricsFileAvailability: availability
            )
            while menu.numberOfItems > secondSectionStart {
                menu.removeItem(at: secondSectionStart)
            }
            items.forEach(menu.addItem)
        }
    }
    return menu
}
