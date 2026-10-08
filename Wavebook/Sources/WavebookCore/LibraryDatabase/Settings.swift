import Foundation
import GRDB

/// Immutable settings loaded together for startup configuration.
public struct LibraryStartupSettings: Equatable, Sendable {
    public let volume: Float
    public let skipSilentSegments: Bool
    public let autoContinuePlaybackAfterOutputChange: Bool
    public let replayGainMode: ReplayGainMode
    public let replayGainAnalysisFileConcurrency: Int
    public let selectedOutputDeviceUID: String?
    public let hiddenOutputDeviceUIDs: Set<String>

    public init(
        volume: Float,
        skipSilentSegments: Bool,
        replayGainMode: ReplayGainMode,
        replayGainAnalysisFileConcurrency: Int,
        selectedOutputDeviceUID: String?,
        hiddenOutputDeviceUIDs: Set<String>,
        autoContinuePlaybackAfterOutputChange: Bool = true
    ) {
        self.volume = volume
        self.skipSilentSegments = skipSilentSegments
        self.autoContinuePlaybackAfterOutputChange = autoContinuePlaybackAfterOutputChange
        self.replayGainMode = replayGainMode
        self.replayGainAnalysisFileConcurrency = replayGainAnalysisFileConcurrency
        self.selectedOutputDeviceUID = selectedOutputDeviceUID
        self.hiddenOutputDeviceUIDs = hiddenOutputDeviceUIDs
    }
}

extension LibraryDatabase {
    /// Loads startup settings in one database read transaction.
    public func startupSettings() throws -> LibraryStartupSettings {
        try writer.read { database in
            let volume = Float(
                min(
                    max(
                        try Double.fetchOne(
                            database,
                            sql: "SELECT value FROM settings WHERE key = 'volume'"
                        ) ?? 1,
                        0
                    ),
                    1
                )
            )
            let skipSilentSegments = (try Double.fetchOne(
                database,
                sql: "SELECT value FROM settings WHERE key = 'skipSilentSegments'"
            ) ?? 0) != 0
            let autoContinuePlaybackAfterOutputChange = (try Double.fetchOne(
                database,
                sql: "SELECT value FROM settings WHERE key = 'autoContinuePlaybackAfterOutputChange'"
            ) ?? 1) != 0
            let replayGainMode = ReplayGainMode(
                rawValue: try String.fetchOne(
                    database,
                    sql: "SELECT value FROM textSettings WHERE key = 'replayGainMode'"
                ) ?? ""
            ) ?? .defaultValue
            let concurrency = ReplayGain.clampedAnalysisFileConcurrency(
                Int(
                    try String.fetchOne(
                        database,
                        sql: "SELECT value FROM textSettings WHERE key = 'replayGainAnalysisFileConcurrency'"
                    ) ?? ""
                ) ?? ReplayGain.defaultAnalysisFileConcurrency
            )
            let selectedUID = try String.fetchOne(
                database,
                sql: "SELECT value FROM textSettings WHERE key = 'selectedOutputDeviceUID'"
            )
            let hiddenUIDs = Set(
                (try String.fetchOne(
                    database,
                    sql: "SELECT value FROM textSettings WHERE key = 'hiddenOutputDeviceUIDs'"
                ) ?? "")
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            return LibraryStartupSettings(
                volume: volume,
                skipSilentSegments: skipSilentSegments,
                replayGainMode: replayGainMode,
                replayGainAnalysisFileConcurrency: concurrency,
                selectedOutputDeviceUID: selectedUID?.isEmpty == true ? nil : selectedUID,
                hiddenOutputDeviceUIDs: hiddenUIDs,
                autoContinuePlaybackAfterOutputChange: autoContinuePlaybackAfterOutputChange
            )
        }
    }

    /// Reads the configured ReplayGain mode.
    public func replayGainMode() throws -> ReplayGainMode {
        try writer.read { database in
            guard
                let value = try String.fetchOne(
                    database,
                    sql: "SELECT value FROM textSettings WHERE key = 'replayGainMode'"
                ),
                let mode = ReplayGainMode(rawValue: value)
            else {
                return .defaultValue
            }
            return mode
        }
    }

    /// Persists the configured ReplayGain mode.
    public func saveReplayGainMode(_ mode: ReplayGainMode) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO textSettings (key, value)
                VALUES ('replayGainMode', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [mode.rawValue]
            )
        }
    }
    /// Reads the configured ReplayGain analysis concurrency.
    public func replayGainAnalysisFileConcurrency() throws -> Int {
        try writer.read { database in
            guard
                let value = try String.fetchOne(
                    database,
                    sql: "SELECT value FROM textSettings WHERE key = 'replayGainAnalysisFileConcurrency'"
                ),
                let concurrency = Int(value)
            else {
                return ReplayGain.defaultAnalysisFileConcurrency
            }
            return ReplayGain.clampedAnalysisFileConcurrency(concurrency)
        }
    }

    /// Persists the configured ReplayGain analysis concurrency.
    public func saveReplayGainAnalysisFileConcurrency(_ value: Int) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO textSettings (key, value)
                VALUES ('replayGainAnalysisFileConcurrency', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [String(ReplayGain.clampedAnalysisFileConcurrency(value))]
            )
        }
    }
    /// Reads normalized playback volume for an output device, falling back to the legacy volume.
    public func volume() throws -> Float {
        try volume(forOutputDeviceUID: nil)
    }

    /// Reads the saved volume for an output device or the legacy volume when none is saved.
    public func volume(forOutputDeviceUID deviceUID: String?) throws -> Float {
        let key = Self.volumeSettingKey(forOutputDeviceUID: deviceUID)
        return try writer.read { database in
            let deviceValue = try key.flatMap { key in
                try Double.fetchOne(database, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
            }
            let value: Double
            if let deviceValue {
                value = deviceValue
            } else {
                value = try Double.fetchOne(database, sql: "SELECT value FROM settings WHERE key = 'volume'") ?? 1
            }
            return Float(min(max(value, 0), 1))
        }
    }

    /// Persists the legacy playback volume.
    public func saveVolume(_ volume: Float) throws {
        try saveVolume(volume, forOutputDeviceUID: nil)
    }

    /// Persists a normalized playback volume for an output device.
    public func saveVolume(_ volume: Float, forOutputDeviceUID deviceUID: String?) throws {
        let key = Self.volumeSettingKey(forOutputDeviceUID: deviceUID) ?? "volume"
        let safeVolume = volume.isFinite ? min(max(Double(volume), 0), 1) : 1
        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, safeVolume]
            )
        }
    }

    private static func volumeSettingKey(forOutputDeviceUID deviceUID: String?) -> String? {
        guard let uid = deviceUID?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else { return nil }
        return "volume:\(uid)"
    }
    /// Returns whether silent segments should be skipped.
    public func skipSilentSegments() throws -> Bool {
        try writer.read { database in
            let value = try Double.fetchOne(
                database,
                sql: "SELECT value FROM settings WHERE key = 'skipSilentSegments'"
            ) ?? 0
            return value != 0
        }
    }

    /// Persists whether silent segments should be skipped.
    public func saveSkipSilentSegments(_ enabled: Bool) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES ('skipSilentSegments', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [enabled ? 1.0 : 0.0]
            )
        }
    }

    /// Persists whether playback should resume after an output-device change.
    public func saveAutoContinuePlaybackAfterOutputChange(_ enabled: Bool) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES ('autoContinuePlaybackAfterOutputChange', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [enabled ? 1.0 : 0.0]
            )
        }
    }

    /// Reads the selected output device identifier.
    public func selectedOutputDeviceUID() throws -> String? {
        try writer.read { database in
            guard
                let uid = try String.fetchOne(
                    database,
                    sql: "SELECT value FROM textSettings WHERE key = 'selectedOutputDeviceUID'"
                )
            else { return nil }
            return uid.isEmpty ? nil : uid
        }
    }

    /// Persists the selected output device identifier.
    public func saveSelectedOutputDeviceUID(_ uid: String?) throws {
        let uid = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { database in
            guard let uid, !uid.isEmpty else {
                try database.execute(sql: "DELETE FROM textSettings WHERE key = 'selectedOutputDeviceUID'")
                return
            }
            try database.execute(
                sql: """
                INSERT INTO textSettings (key, value)
                VALUES ('selectedOutputDeviceUID', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [uid]
            )
        }
    }

    /// Reads identifiers of output devices hidden by the user.
    public func hiddenOutputDeviceUIDs() throws -> Set<String> {
        try writer.read { database in
            let value = try String.fetchOne(
                database,
                sql: "SELECT value FROM textSettings WHERE key = 'hiddenOutputDeviceUIDs'"
            ) ?? ""
            return Set(
                value.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    /// Persists identifiers of output devices hidden by the user.
    public func saveHiddenOutputDeviceUIDs(_ uids: Set<String>) throws {
        let value = uids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "\n")
        try writer.write { database in
            guard !value.isEmpty else {
                try database.execute(sql: "DELETE FROM textSettings WHERE key = 'hiddenOutputDeviceUIDs'")
                return
            }
            try database.execute(
                sql: """
                INSERT INTO textSettings (key, value)
                VALUES ('hiddenOutputDeviceUIDs', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [value]
            )
        }
    }

    /// Persists selected and hidden output-device configuration.
    public func saveOutputConfiguration(selectedUID: String?, hiddenUIDs: Set<String>) throws {
        let selectedUID = selectedUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hiddenValue = hiddenUIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "\n")
        try writer.write { database in
            if let selectedUID, !selectedUID.isEmpty {
                try database.execute(
                    sql: """
                    INSERT INTO textSettings (key, value)
                    VALUES ('selectedOutputDeviceUID', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [selectedUID]
                )
            } else {
                try database.execute(sql: "DELETE FROM textSettings WHERE key = 'selectedOutputDeviceUID'")
            }

            if hiddenValue.isEmpty {
                try database.execute(sql: "DELETE FROM textSettings WHERE key = 'hiddenOutputDeviceUIDs'")
            } else {
                try database.execute(
                    sql: """
                    INSERT INTO textSettings (key, value)
                    VALUES ('hiddenOutputDeviceUIDs', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [hiddenValue]
                )
            }
        }
    }

    /// Loads an equalizer profile, falling back to the default profile.
    public func equalizerProfile(deviceUID: String? = nil) throws -> EqualizerProfile {
        let requestedUID = normalizedDeviceUID(deviceUID)
        return try writer.read { database in
            if let profile = try Self.equalizerProfile(deviceUID: requestedUID, db: database) {
                return profile
            }
            return .flat(deviceUID: requestedUID)
        }
    }

    /// Loads a stored equalizer profile without applying a fallback.
    public func storedEqualizerProfile(deviceUID: String? = nil) throws -> EqualizerProfile? {
        let requestedUID = normalizedDeviceUID(deviceUID)
        return try writer.read { database in
            try Self.equalizerProfile(deviceUID: requestedUID, db: database)
        }
    }

    /// Persists an equalizer profile.
    public func saveEqualizerProfile(_ profile: EqualizerProfile) throws {
        let profile = EqualizerProfile(
            deviceUID: profile.deviceUID,
            preamp: profile.preamp,
            isBypassed: profile.isBypassed,
            bandGains: profile.bandGains
        )
        let bandsJSON = String(
            bytes: try JSONEncoder().encode(profile.bandGains),
            encoding: .utf8
        ) ?? ""

        try writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO eqProfiles (deviceUID, preamp, isBypassed, bandsJSON)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceUID) DO UPDATE SET
                    preamp = excluded.preamp,
                    isBypassed = excluded.isBypassed,
                    bandsJSON = excluded.bandsJSON
                """,
                arguments: [profile.deviceUID, profile.preamp, profile.isBypassed, bandsJSON]
            )
        }
    }

    /// Moves the default equalizer profile to a device-specific identifier.
    public func migrateDefaultEqualizerProfile(toDeviceUID deviceUID: String) throws -> EqualizerProfile? {
        let deviceUID = normalizedDeviceUID(deviceUID)
        guard deviceUID != EqualizerProfile.defaultDeviceUID else {
            return try storedEqualizerProfile()
        }

        return try writer.write { database in
            guard let profile = try Self.equalizerProfile(
                deviceUID: EqualizerProfile.defaultDeviceUID,
                db: database
            ) else {
                return nil
            }

            let migratedProfile = EqualizerProfile(
                deviceUID: deviceUID,
                preamp: profile.preamp,
                isBypassed: profile.isBypassed,
                bandGains: profile.bandGains
            )
            let bandsJSON = String(
                bytes: try JSONEncoder().encode(migratedProfile.bandGains),
                encoding: .utf8
            ) ?? ""
            try database.execute(
                sql: """
                INSERT INTO eqProfiles (deviceUID, preamp, isBypassed, bandsJSON)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(deviceUID) DO UPDATE SET
                    preamp = excluded.preamp,
                    isBypassed = excluded.isBypassed,
                    bandsJSON = excluded.bandsJSON
                """,
                arguments: [migratedProfile.deviceUID, migratedProfile.preamp, migratedProfile.isBypassed, bandsJSON]
            )
            try database.execute(
                sql: "DELETE FROM eqProfiles WHERE deviceUID = ?",
                arguments: [EqualizerProfile.defaultDeviceUID]
            )
            return migratedProfile
        }
    }
}
