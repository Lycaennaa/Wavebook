import Foundation
import GRDB

extension LibraryDatabase {
    static func equalizerProfile(deviceUID: String, db database: Database) throws -> EqualizerProfile? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT deviceUID, preamp, isBypassed, bandsJSON FROM eqProfiles WHERE deviceUID = ?",
            arguments: [deviceUID]
        ) else {
            return nil
        }
        let bandsJSON: String = row["bandsJSON"]
        let bandGains = try JSONDecoder().decode([Double].self, from: Data(bandsJSON.utf8))
        return EqualizerProfile(
            deviceUID: row["deviceUID"],
            preamp: row["preamp"],
            isBypassed: row["isBypassed"],
            bandGains: bandGains
        )
    }

    func normalizedDeviceUID(_ deviceUID: String?) -> String {
        guard let deviceUID, !deviceUID.isEmpty else { return EqualizerProfile.defaultDeviceUID }
        return deviceUID
    }
}
