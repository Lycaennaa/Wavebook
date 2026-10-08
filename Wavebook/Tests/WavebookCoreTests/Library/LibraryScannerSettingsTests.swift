import Foundation
@testable import WavebookCore
import XCTest

extension LibraryScannerTests {
    func testRootsPersistInPathOrder() throws {
        let database = try LibraryDatabase(inMemory: true)

        _ = try database.addRoot(path: "/z")
        _ = try database.addRoot(path: "/a")

        XCTAssertEqual(try database.roots().map(\.path), ["/a", "/z"])
    }

    func testVolumePersistsAndClamps() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertEqual(try database.volume(), 1)

        try database.saveVolume(0.42)
        XCTAssertEqual(try database.volume(), 0.42, accuracy: 0.001)

        try database.saveVolume(2)
        XCTAssertEqual(try database.volume(), 1)
    }

    func testOutputDeviceVolumesPersistSeparatelyAndFallBackToLegacyVolume() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path

        do {
            let database = try LibraryDatabase(path: path)
            try database.saveVolume(0.42)
            XCTAssertEqual(try database.volume(forOutputDeviceUID: "device-1"), 0.42, accuracy: 0.001)

            try database.saveVolume(0.25, forOutputDeviceUID: "device-1")
            try database.saveVolume(2, forOutputDeviceUID: "device-2")
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertEqual(try reopened.volume(forOutputDeviceUID: "device-1"), 0.25, accuracy: 0.001)
        XCTAssertEqual(try reopened.volume(forOutputDeviceUID: "device-2"), 1, accuracy: 0.001)
        XCTAssertEqual(try reopened.volume(forOutputDeviceUID: "device-3"), 0.42, accuracy: 0.001)
        XCTAssertEqual(try reopened.volume(), 0.42, accuracy: 0.001)
    }
    func testSkipSilentSegmentsPersistsAndDefaultsOff() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertFalse(try database.skipSilentSegments())

        try database.saveSkipSilentSegments(true)
        XCTAssertTrue(try database.skipSilentSegments())

        try database.saveSkipSilentSegments(false)
        XCTAssertFalse(try database.skipSilentSegments())
    }
    func testSkipSilentSegmentsPersistsAcrossDatabaseReopen() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path

        do {
            let database = try LibraryDatabase(path: path)
            try database.saveSkipSilentSegments(true)
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertTrue(try reopened.skipSilentSegments())
    }

    func testAutoContinuePlaybackAfterOutputChangeDefaultsOnAndPersistsAcrossReopen() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path

        do {
            let database = try LibraryDatabase(path: path)
            XCTAssertTrue(try database.startupSettings().autoContinuePlaybackAfterOutputChange)
            try database.saveAutoContinuePlaybackAfterOutputChange(false)
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertFalse(try reopened.startupSettings().autoContinuePlaybackAfterOutputChange)
    }

    func testSelectedOutputDevicePersistsAndClears() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertNil(try database.selectedOutputDeviceUID())

        try database.saveSelectedOutputDeviceUID("device-1")
        XCTAssertEqual(try database.selectedOutputDeviceUID(), "device-1")

        try database.saveSelectedOutputDeviceUID(nil)
        XCTAssertNil(try database.selectedOutputDeviceUID())
    }

    func testSelectedOutputDevicePersistsAcrossDatabaseReopen() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path

        do {
            let database = try LibraryDatabase(path: path)
            try database.saveSelectedOutputDeviceUID("device-1")
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertEqual(try reopened.selectedOutputDeviceUID(), "device-1")
    }

    func testHiddenOutputDeviceUIDsPersistAndClear() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path

        do {
            let database = try LibraryDatabase(path: path)
            XCTAssertEqual(try database.hiddenOutputDeviceUIDs(), [])
            try database.saveHiddenOutputDeviceUIDs(["device-2", "device-1", ""])
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertEqual(try reopened.hiddenOutputDeviceUIDs(), ["device-1", "device-2"])

        try reopened.saveHiddenOutputDeviceUIDs([])
        XCTAssertEqual(try reopened.hiddenOutputDeviceUIDs(), [])
    }

    func testOutputConfigurationSavesSelectionAndHiddenDevicesTogether() throws {
        let database = try LibraryDatabase(inMemory: true)
        try database.saveSelectedOutputDeviceUID("device-1")

        try database.saveOutputConfiguration(selectedUID: nil, hiddenUIDs: ["device-1", "device-2"])

        XCTAssertNil(try database.selectedOutputDeviceUID())
        XCTAssertEqual(try database.hiddenOutputDeviceUIDs(), ["device-1", "device-2"])
    }
    func testStartupSettingsLoadsPersistedValues() throws {
        let database = try LibraryDatabase(inMemory: true)
        try database.saveVolume(0.42)
        try database.saveSkipSilentSegments(true)
        try database.saveReplayGainMode(.album)
        try database.saveReplayGainAnalysisFileConcurrency(3)
        try database.saveOutputConfiguration(selectedUID: "device-1", hiddenUIDs: ["device-2"])

        let settings = try database.startupSettings()
        XCTAssertEqual(settings.volume, 0.42, accuracy: 0.001)
        XCTAssertTrue(settings.skipSilentSegments)
        XCTAssertEqual(settings.replayGainMode, .album)
        XCTAssertEqual(settings.replayGainAnalysisFileConcurrency, 3)
        XCTAssertEqual(settings.selectedOutputDeviceUID, "device-1")
        XCTAssertEqual(settings.hiddenOutputDeviceUIDs, ["device-2"])
    }

    func testEqualizerProfileDefaultsToFlat31BandProfile() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertNil(try database.storedEqualizerProfile())

        let profile = try database.equalizerProfile()

        XCTAssertEqual(profile.deviceUID, EqualizerProfile.defaultDeviceUID)
        XCTAssertEqual(profile.preamp, 0)
        XCTAssertTrue(profile.isBypassed)
        XCTAssertEqual(profile.bandGains, Array(repeating: 0, count: EqualizerProfile.bandCount))
    }

    func testEqualizerProfilePersistsBandsPreampAndBypass() throws {
        let database = try LibraryDatabase(inMemory: true)
        let gains = (0..<EqualizerProfile.bandCount).map { Double($0 % 12) - 6 }
        let profile = EqualizerProfile(deviceUID: "device-1", preamp: -3.5, isBypassed: false, bandGains: gains)

        try database.saveEqualizerProfile(profile)

        XCTAssertEqual(try database.storedEqualizerProfile(deviceUID: "device-1"), profile)
        XCTAssertEqual(try database.equalizerProfile(deviceUID: "device-1"), profile)
    }

    func testEqualizerProfilePersistsAcrossDatabaseReopenForDeviceUID() throws {
        let path = try makeRoot().appending(path: "Library.sqlite").path
         let profile = EqualizerProfile(
             deviceUID: "device-1",
             preamp: -3.5,
             isBypassed: false,
             bandGains: Array(repeating: 1.5, count: EqualizerProfile.bandCount)
         )

        do {
            let database = try LibraryDatabase(path: path)
            try database.saveEqualizerProfile(profile)
        }

        let reopened = try LibraryDatabase(path: path)
        XCTAssertEqual(try reopened.equalizerProfile(deviceUID: "device-1"), profile)
        XCTAssertEqual(try reopened.equalizerProfile(deviceUID: "device-2"), .flat(deviceUID: "device-2"))
    }

    func testDefaultEqualizerProfileMigratesToActiveDevice() throws {
        let database = try LibraryDatabase(inMemory: true)
         let globalProfile = EqualizerProfile(
             preamp: -4,
             isBypassed: false,
             bandGains: Array(repeating: 2, count: EqualizerProfile.bandCount)
         )
        let staleDeviceProfile = EqualizerProfile(deviceUID: "device-1", preamp: 3, isBypassed: true)
        try database.saveEqualizerProfile(globalProfile)
        try database.saveEqualizerProfile(staleDeviceProfile)

        let migrated = try database.migrateDefaultEqualizerProfile(toDeviceUID: "device-1")

         XCTAssertEqual(
             migrated,
             EqualizerProfile(
                 deviceUID: "device-1",
                 preamp: -4,
                 isBypassed: false,
                 bandGains: globalProfile.bandGains
             )
         )
        XCTAssertEqual(try database.storedEqualizerProfile(deviceUID: "device-1"), migrated)
        XCTAssertNil(try database.storedEqualizerProfile())
    }

    func testMissingDefaultEqualizerProfileDoesNotReplaceDeviceProfile() throws {
        let database = try LibraryDatabase(inMemory: true)
        let profile = EqualizerProfile(deviceUID: "device-1", preamp: -3.5, isBypassed: false)
        try database.saveEqualizerProfile(profile)

        XCTAssertNil(try database.migrateDefaultEqualizerProfile(toDeviceUID: "device-1"))
        XCTAssertEqual(try database.storedEqualizerProfile(deviceUID: "device-1"), profile)
    }

    func testEqualizerProfileFallsBackToFlatProfileForRequestedDevice() throws {
        let database = try LibraryDatabase(inMemory: true)

        XCTAssertEqual(try database.equalizerProfile(deviceUID: "missing-device"), .flat(deviceUID: "missing-device"))
    }

    func testEqualizerProfileClampsToTwelveDb() {
        let profile = EqualizerProfile(preamp: 99, bandGains: [-99, 0, 99])

        XCTAssertEqual(profile.preamp, 12)
        XCTAssertEqual(profile.bandGains[0], -12)
        XCTAssertEqual(profile.bandGains[1], 0)
        XCTAssertEqual(profile.bandGains[2], 12)
    }

    func testEqualizerImportAppliesNearestFrequencyBands() throws {
        let profile = try EqualizerProfile.flat().applyingImportedBands("20\t9.9\n25\t8.8\n32\t6.9")

        XCTAssertFalse(profile.isBypassed)
        XCTAssertEqual(profile.bandGains[EqualizerProfile.nearestBandIndex(to: 20)], 9.9)
        XCTAssertEqual(profile.bandGains[EqualizerProfile.nearestBandIndex(to: 25)], 8.8)
        XCTAssertEqual(profile.bandGains[EqualizerProfile.nearestBandIndex(to: 32)], 6.9)
    }

    func testNearestEqualizerBandMatchesExhaustiveLogDistance() {
        let bands = EqualizerProfile.frequencies
        var probes = bands + [Double.leastNonzeroMagnitude, 1, 50_000, .nan, .infinity]
        for index in 0..<(bands.count - 1) {
            let midpoint = (bands[index] * bands[index + 1]).squareRoot()
            probes.append(contentsOf: [midpoint.nextDown, midpoint, midpoint.nextUp])
        }

        for frequency in probes {
            let expected = frequency.isFinite && frequency > 0
                ? bands.indices.min { left, right in
                    abs(log(frequency / bands[left])) < abs(log(frequency / bands[right]))
                } ?? 0
                : 0
            XCTAssertEqual(EqualizerProfile.nearestBandIndex(to: frequency), expected)
        }
    }

    func testEqualizerImportRejectsInvalidLines() throws {
        XCTAssertThrowsError(try EqualizerProfile.flat().applyingImportedBands("20 1\noops")) { error in
            XCTAssertEqual(error as? EqualizerImportError, .invalidLine(2))
        }
    }

    func testEqualizerImportRejectsNonFiniteFrequency() {
        XCTAssertThrowsError(try EqualizerProfile.flat().applyingImportedBands("inf 1"))
        XCTAssertThrowsError(try EqualizerProfile.flat().applyingImportedBands("nan 1"))
        XCTAssertEqual(EqualizerProfile.nearestBandIndex(to: .infinity), 0)
    }

    func testEqualizerDecodingRestoresBandInvariant() throws {
         let profile = try JSONDecoder().decode(
             EqualizerProfile.self,
             from: Data(#"{"deviceUID":"","preamp":99,"isBypassed":false,"bandGains":[-99,2,99]}"#.utf8)
         )
        XCTAssertEqual(profile.deviceUID, EqualizerProfile.defaultDeviceUID)
        XCTAssertEqual(profile.preamp, 12)
        XCTAssertEqual(profile.bandGains.count, EqualizerProfile.bandCount)
        XCTAssertEqual(Array(profile.bandGains.prefix(3)), [-12, 2, 12])
    }
}
