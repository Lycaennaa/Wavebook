import Foundation

enum LibraryPage: String, CaseIterable, Sendable {
    case search = "Search"
    case songs = "Songs"
    case artists = "Artists"
    case albums = "Albums"
    case genres = "Genres"
    case statistics = "Statistics"
    case playlists = "Playlists"
    case queue = "Queue"
    case settings = "Settings"
}
