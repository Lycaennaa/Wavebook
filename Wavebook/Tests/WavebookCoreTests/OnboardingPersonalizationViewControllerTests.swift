import AppKit
import WavebookCore
import XCTest

@MainActor
final class OnboardingPersonalizationViewControllerTests: XCTestCase {
    func testPreferenceChoicesReflectCurrentSettingsAndRevertFailedWrites() throws {
        _ = NSApplication.shared
        var appearanceChanges: [AppAppearance] = []
        var replayGainModes: [ReplayGainMode] = []
        var skipSilentWrites: [Bool] = []
        var replayGainWriteSucceeds = false
        var skipSilentWriteSucceeds = false
        let controller = makeController(
            appearance: .light,
            replayGainMode: .album,
            skipSilentSegments: true,
            onAppearanceChanged: { appearanceChanges.append($0) },
            onReplayGainModeChanged: {
                replayGainModes.append($0)
                return replayGainWriteSucceeds
            },
            onSkipSilentSegmentsChanged: {
                skipSilentWrites.append($0)
                return skipSilentWriteSucceeds
            }
        )
        let root = controller.view
        let popups = descendants(of: NSPopUpButton.self, in: root)
        let appearancePopup = try XCTUnwrap(popups.first)
        let replayGainPopup = try XCTUnwrap(popups.dropFirst().first)
        let skipButton = try XCTUnwrap(descendants(of: NSButton.self, in: root).first {
            $0.title == "Skip silence at the start and end of songs"
        })

        XCTAssertEqual(appearancePopup.selectedItem?.representedObject as? AppAppearance, .light)
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .album)
        XCTAssertEqual(skipButton.state, .on)

        appearancePopup.selectItem(withTitle: "Dark")
        sendAction(of: appearancePopup)
        XCTAssertEqual(appearanceChanges, [.dark])

        replayGainPopup.selectItem(withTitle: "Track")
        sendAction(of: replayGainPopup)
        XCTAssertEqual(replayGainModes, [.track])
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .album)

        skipButton.state = .off
        sendAction(of: skipButton)
        XCTAssertEqual(skipSilentWrites, [false])
        XCTAssertEqual(skipButton.state, .on)

        replayGainWriteSucceeds = true
        replayGainPopup.selectItem(withTitle: "Off")
        sendAction(of: replayGainPopup)
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .off)

        skipSilentWriteSucceeds = true
        skipButton.state = .off
        sendAction(of: skipButton)
        XCTAssertEqual(skipButton.state, .off)
    }

    func testGuidanceExplainsSystemDefaultBlackThemeReplayGainAndPersonalEQ() throws {
        _ = NSApplication.shared
        let controller = makeController(
            appearance: .system,
            replayGainMode: .off,
            skipSilentSegments: false
        )
        let root = controller.view
        let descriptions = descendants(of: NSTextField.self, in: root).map(\.stringValue)
        let appearancePopup = try XCTUnwrap(descendants(of: NSPopUpButton.self, in: root).first)

        XCTAssertEqual(appearancePopup.selectedItem?.representedObject as? AppAppearance, .system)
        XCTAssertEqual(appearancePopup.itemArray.map(\.title), ["System (Apple)", "Light", "Dark", "AMOLED Black"])
        XCTAssertTrue(descriptions.contains { $0.contains("System is the default") })
        XCTAssertTrue(descriptions.contains {
            $0.contains("Keeps songs from suddenly sounding much louder or quieter")
        })
        XCTAssertTrue(descriptions.contains { $0.contains("Your personal EQ settings") })
    }

    func testBackSkipExitFinishAndEqualizerActionsAreForwarded() throws {
        _ = NSApplication.shared
        var actions: [String] = []
        let controller = makeController(
            appearance: .system,
            replayGainMode: .off,
            skipSilentSegments: false,
            onOpenEqualizer: { actions.append("equalizer") },
            onBack: { actions.append("back") },
            onReturnToLibrary: { actions.append("library") }
        )
        let buttons = descendants(of: NSButton.self, in: controller.view)
        for title in ["Back", "Skip Step", "Exit Onboarding", "Finish", "Open 31-band EQ…"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            sendAction(of: button)
        }

        XCTAssertEqual(actions, ["back", "library", "library", "library", "equalizer"])
    }

    private func makeController(
        appearance: AppAppearance,
        replayGainMode: ReplayGainMode,
        skipSilentSegments: Bool,
        onAppearanceChanged: @escaping (AppAppearance) -> Void = { _ in },
        onReplayGainModeChanged: @escaping (ReplayGainMode) -> Bool = { _ in true },
        onSkipSilentSegmentsChanged: @escaping (Bool) -> Bool = { _ in true },
        onOpenEqualizer: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onReturnToLibrary: @escaping () -> Void = {}
    ) -> OnboardingPersonalizationViewController {
        OnboardingPersonalizationViewController(
            appearance: appearance,
            replayGainMode: replayGainMode,
            skipSilentSegments: skipSilentSegments,
            onAppearanceChanged: onAppearanceChanged,
            onReplayGainModeChanged: onReplayGainModeChanged,
            onSkipSilentSegmentsChanged: onSkipSilentSegmentsChanged,
            onOpenEqualizer: onOpenEqualizer,
            onBack: onBack,
            onReturnToLibrary: onReturnToLibrary
        )
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        for subview in root.subviews {
            if let matchingView = subview as? T {
                result.append(matchingView)
            }
            result.append(contentsOf: descendants(of: type, in: subview))
        }
        return result
    }

    private func sendAction(of control: NSControl, file: StaticString = #filePath, line: UInt = #line) {
        guard let action = control.action else {
            XCTFail("Control has no action", file: file, line: line)
            return
        }
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
    }
}
