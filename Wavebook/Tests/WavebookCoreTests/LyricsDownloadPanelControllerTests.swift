import AppKit
import Foundation
@testable import WavebookCore
import XCTest

@MainActor
final class LyricsDownloadPanelControllerTests: XCTestCase {
    func testSearchDisclosesMetadataAndSendsOnlyCheckedFields() async throws {
        _ = NSApplication.shared
        let requestObserved = expectation(description: "LRCLIB search request")
        let requestCapture = SearchRequestCapture()
        let downloader = LRCLIBLyricsDownloader { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                  ) else {
                throw URLError(.badURL)
            }
            await requestCapture.record(url)
            requestObserved.fulfill()
            return (Data("[]".utf8), response)
        }
        let track = Track(
            path: "/Music/song.mp3",
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album"
        )
        let controller = LyricsDownloadPanelController(track: track, downloader: downloader)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let labels: [NSTextField] = appKitDescendants(of: NSTextField.self, in: content)
        let disclosure = try XCTUnwrap(labels.first { $0.stringValue.contains("Only checked, non-empty") })
        XCTAssertEqual(disclosure.accessibilityLabel(), "Lyrics lookup privacy notice")
        XCTAssertTrue(disclosure.stringValue.contains("No audio files are sent."))

        let buttons: [NSButton] = appKitDescendants(of: NSButton.self, in: content)
        let titleCheck = try XCTUnwrap(buttons.first { $0.title == "Title" })
        let artistCheck = try XCTUnwrap(buttons.first { $0.title == "Artist" })
        let albumCheck = try XCTUnwrap(buttons.first { $0.title == "Album" })
        let keywordsCheck = try XCTUnwrap(buttons.first { $0.title == "Keywords" })
        titleCheck.state = .off
        artistCheck.state = .on
        albumCheck.state = .off
        keywordsCheck.state = .on
        let keywordsField = try XCTUnwrap(labels.first { $0.placeholderString == "Optional free-text search" })
        keywordsField.stringValue = " live "

        let searchButton = try XCTUnwrap(buttons.first { $0.title == "Search LRCLIB" })
        XCTAssertEqual(searchButton.accessibilityHelp()?.contains("No audio files are sent."), true)
        sendAppKitAction(searchButton)
        await fulfillment(of: [requestObserved], timeout: 10)

        let capturedURL = await requestCapture.url
        let url = try XCTUnwrap(capturedURL)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryValue("artist_name", in: queryItems), "Artist")
        XCTAssertEqual(queryValue("q", in: queryItems), "live")
        XCTAssertNil(queryValue("track_name", in: queryItems))
        XCTAssertNil(queryValue("album_name", in: queryItems))
    }

    private func queryValue(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }
}

private actor SearchRequestCapture {
    private(set) var url: URL?

    func record(_ url: URL) {
        self.url = url
    }
}
