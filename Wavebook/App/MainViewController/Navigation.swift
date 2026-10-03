import AppKit
import Foundation
import WavebookCore

extension MainViewController {
    @objc func searchChanged() {
        navigation.updateQuery(searchField.stringValue)
    }

    func showPage(_ page: LibraryPage) {
        clearSearch()
        navigation.showPage(page)
    }

    func openAlbum(_ key: AlbumKey) {
        clearSearch()
        navigation.show(destination: .catalog(.albums(selectedAlbum: key)), recordHistory: true)
    }

    func openArtist(_ artist: String) {
        clearSearch()
        navigation.show(destination: .catalog(.artists(selectedArtist: artist)), recordHistory: true)
    }

    func openGenre(_ genre: String) {
        clearSearch()
        navigation.show(destination: .catalog(.genres(selectedGenre: genre)), recordHistory: true)
    }

    func clearSearch() {
        navigation.clearQuery()
        searchField.stringValue = ""
    }

    @objc func goBack() {
        navigation.goBack()
    }

    @objc func goForward() {
        navigation.goForward()
    }
}
