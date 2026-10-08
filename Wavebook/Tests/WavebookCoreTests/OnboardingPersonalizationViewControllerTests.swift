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
        let popups = appKitDescendants(of: NSPopUpButton.self, in: root)
        let appearancePopup = try XCTUnwrap(popups.first)
        let replayGainPopup = try XCTUnwrap(popups.dropFirst().first)
        let buttons = appKitDescendants(of: NSButton.self, in: root)
        let skipButton = try XCTUnwrap(buttons.first {
            $0.title == "Skip silence at the start and end of songs"
        })

        XCTAssertEqual(appearancePopup.selectedItem?.representedObject as? AppAppearance, .light)
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .album)
        XCTAssertEqual(skipButton.state, .on)

        appearancePopup.selectItem(withTitle: "Dark")
        sendAppKitAction(appearancePopup)
        XCTAssertEqual(appearanceChanges, [.dark])

        replayGainPopup.selectItem(withTitle: "Track")
        sendAppKitAction(replayGainPopup)
        XCTAssertEqual(replayGainModes, [.track])
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .album)

        skipButton.state = .off
        sendAppKitAction(skipButton)
        XCTAssertEqual(skipSilentWrites, [false])
        XCTAssertEqual(skipButton.state, .on)

        replayGainWriteSucceeds = true
        replayGainPopup.selectItem(withTitle: "Off")
        sendAppKitAction(replayGainPopup)
        XCTAssertEqual(replayGainPopup.selectedItem?.representedObject as? ReplayGainMode, .off)

        skipSilentWriteSucceeds = true
        skipButton.state = .off
        sendAppKitAction(skipButton)
        XCTAssertEqual(skipButton.state, .off)
    }

    func testAutoContinueSettingRevertsFailedWritesAndKeepsSuccessfulValue() throws {
        _ = NSApplication.shared
        var values: [Bool] = []
        var writeSucceeds = false
        let controller = makeController(
            appearance: .system,
            replayGainMode: .off,
            skipSilentSegments: false,
            autoContinuePlaybackAfterOutputChange: true,
            onAutoContinuePlaybackAfterOutputChange: {
                values.append($0)
                return writeSucceeds
            }
        )
        let button = try XCTUnwrap(appKitDescendants(of: NSButton.self, in: controller.view).first {
            $0.title == "Continue playback after output changes"
        })
        XCTAssertEqual(button.state, .on)

        button.state = .off
        sendAppKitAction(button)
        XCTAssertEqual(values, [false])
        XCTAssertEqual(button.state, .on)

        writeSucceeds = true
        button.state = .off
        sendAppKitAction(button)
        XCTAssertEqual(values, [false, false])
        XCTAssertEqual(button.state, .off)
    }

    func testGuidanceExplainsSystemDefaultBlackThemeReplayGainAndPersonalEQ() throws {
        _ = NSApplication.shared
        let controller = makeController(
            appearance: .system,
            replayGainMode: .off,
            skipSilentSegments: false
        )
        let root = controller.view
        let descriptions = appKitDescendants(of: NSTextField.self, in: root).map(\.stringValue)
        let appearancePopup = try XCTUnwrap(appKitDescendants(of: NSPopUpButton.self, in: root).first)

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
        let buttons = appKitDescendants(of: NSButton.self, in: controller.view)
        for title in ["Back", "Skip Step", "Exit Onboarding", "Finish", "Open 31-band EQ…"] {
            let button = try XCTUnwrap(buttons.first { $0.title == title })
            sendAppKitAction(button)
        }

        XCTAssertEqual(actions, ["back", "library", "library", "library", "equalizer"])
    }

    private func makeController(
        appearance: AppAppearance,
        replayGainMode: ReplayGainMode,
        skipSilentSegments: Bool,
        autoContinuePlaybackAfterOutputChange: Bool = true,
        onAppearanceChanged: @escaping (AppAppearance) -> Void = { _ in },
        onReplayGainModeChanged: @escaping (ReplayGainMode) -> Bool = { _ in true },
        onSkipSilentSegmentsChanged: @escaping (Bool) -> Bool = { _ in true },
        onAutoContinuePlaybackAfterOutputChange: @escaping (Bool) -> Bool = { _ in true },
        onOpenEqualizer: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onReturnToLibrary: @escaping () -> Void = {}
    ) -> OnboardingPersonalizationViewController {
        OnboardingPersonalizationViewController(
            appearance: appearance,
            replayGainMode: replayGainMode,
            skipSilentSegments: skipSilentSegments,
            autoContinuePlaybackAfterOutputChange: autoContinuePlaybackAfterOutputChange,
            onAppearanceChanged: onAppearanceChanged,
            onReplayGainModeChanged: onReplayGainModeChanged,
            onSkipSilentSegmentsChanged: onSkipSilentSegmentsChanged,
            onAutoContinuePlaybackAfterOutputChange: onAutoContinuePlaybackAfterOutputChange,
            onOpenEqualizer: onOpenEqualizer,
            onBack: onBack,
            onReturnToLibrary: onReturnToLibrary
        )
    }

}
