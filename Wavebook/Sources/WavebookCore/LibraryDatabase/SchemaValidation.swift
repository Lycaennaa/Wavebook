import Foundation
import GRDB

extension LibraryDatabase {
    static func hasUserTables(db database: Database) throws -> Bool {
        try Int.fetchOne(
            database,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            )
            """
        ) == 1
    }

}
