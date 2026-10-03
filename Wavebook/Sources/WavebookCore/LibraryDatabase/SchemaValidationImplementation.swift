import Foundation
import GRDB

private func schemaIsIdentifierCharacter(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private func schemaSkipQuotedText(in characters: [Character], from start: Int) -> Int {
    let opening = characters[start]
    let closing = opening == "[" ? "]" : opening
    var index = start + 1
    while index < characters.count {
        if characters[index] == closing {
            if index + 1 < characters.count, characters[index + 1] == closing {
                index += 2
            } else {
                return index + 1
            }
        } else {
            index += 1
        }
    }
    return characters.count
}

private func schemaCheckExpression(
    in characters: [Character],
    from index: Int
) -> (expression: String, nextIndex: Int)? {
    let keywordEnd = index + 5
    guard keywordEnd <= characters.count,
          String(characters[index..<keywordEnd]) == "check",
          index == 0 || !schemaIsIdentifierCharacter(characters[index - 1]),
          keywordEnd == characters.count || !schemaIsIdentifierCharacter(characters[keywordEnd]) else {
        return nil
    }

    var openingParenthesis = keywordEnd
    while openingParenthesis < characters.count, characters[openingParenthesis].isWhitespace {
        openingParenthesis += 1
    }
    guard openingParenthesis < characters.count, characters[openingParenthesis] == "(" else {
        return nil
    }

    var depth = 1
    var cursor = openingParenthesis + 1
    while cursor < characters.count {
        let character = characters[cursor]
        if character == "'" || character == "\"" || character == "`" || character == "[" {
            cursor = schemaSkipQuotedText(in: characters, from: cursor)
            continue
        }
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                return (
                    String(characters[(openingParenthesis + 1)..<cursor]),
                    cursor + 1
                )
            }
        }
        cursor += 1
    }
    return nil
}

func schemaCheckExpressions(in sql: String) -> [String] {
    let characters = Array(sql.lowercased())
    var expressions: [String] = []
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "'" || character == "\"" || character == "`" || character == "[" {
            index = schemaSkipQuotedText(in: characters, from: index)
            continue
        }
        if let check = schemaCheckExpression(in: characters, from: index) {
            expressions.append(check.expression)
            index = check.nextIndex
        } else {
            index += 1
        }
    }
    return expressions
}

extension LibraryDatabase {
    nonisolated(unsafe) private static let validateSchemaImplementation: (Database) throws -> Void = { database in
        let normalizedSQL: (String) -> String = { sql in
            sql.lowercased()
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"\s*,\s*"#, with: ",", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\("#, with: "(", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\)"#, with: ")", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        let columnMetadata: (String, String, Bool, String?) -> String = { name, type, notNull, defaultValue in
            [
                name.lowercased(),
                type.uppercased(),
                notNull ? "1" : "0",
                defaultValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? "NULL"
            ].joined(separator: "|")
        }
        let requiredColumnMetadata = LibraryDatabase.requiredColumnMetadata()

        for table in SchemaValidationSpecification.tables {
            guard let createSQL = try String.fetchOne(
                database,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table.name]
            ) else {
                throw LibraryDatabaseError.invalidSchema("Missing table \(table.name)")
            }

            let tableInfo = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table.name))")
            let actualColumnMetadata = tableInfo.map { row -> String in
                let name: String = row["name"]
                let type: String = row["type"]
                let notNull: Int = row["notnull"]
                let defaultValue: String? = row["dflt_value"]
                return columnMetadata(name, type, notNull == 1, defaultValue)
            }
            guard actualColumnMetadata == (requiredColumnMetadata[table.name] ?? []) else {
                throw LibraryDatabaseError.invalidSchema("Table \(table.name) has the wrong column metadata")
            }

            let normalizedCreateSQL = normalizedSQL(createSQL)
            let missingFragments = table.fragments.filter { !normalizedCreateSQL.contains($0.lowercased()) }
            guard missingFragments.isEmpty else {
                throw LibraryDatabaseError.invalidSchema(
                    "Table \(table.name) missing constraints: \(missingFragments.joined(separator: ", "))"
                )
            }
            let actualCheckDefinitions = schemaCheckExpressions(in: createSQL)
                .map(normalizedSQL)
                .sorted()
            guard actualCheckDefinitions.count == (SchemaValidationSpecification.checkCounts[table.name] ?? 0) else {
                throw LibraryDatabaseError.invalidSchema("Table \(table.name) has unexpected check constraints")
            }
            if let expectedDefinition = SchemaValidationSpecification.tableDefinitions[table.name] {
                let expectedCheckDefinitions = schemaCheckExpressions(in: expectedDefinition)
                    .map(normalizedSQL)
                    .sorted()
                guard actualCheckDefinitions == expectedCheckDefinitions else {
                    throw LibraryDatabaseError.invalidSchema("Table \(table.name) has the wrong check constraints")
                }
            }
        }

        func indexColumns(named indexName: String) throws -> [String] {
            try Row.fetchAll(database, sql: "PRAGMA index_info(\(indexName))")
                .sorted { lhs, rhs in
                    let lhsSequence: Int = lhs["seqno"]
                    let rhsSequence: Int = rhs["seqno"]
                    return lhsSequence < rhsSequence
                }
                .map { row -> String in
                    let name: String? = row["name"]
                    return name ?? ""
                }
        }

        func indexOrdering(named indexName: String) throws -> [String] {
            try Row.fetchAll(database, sql: "PRAGMA index_xinfo(\(indexName))")
                .filter { row in
                    let isKey: Int = row["key"]
                    return isKey == 1
                }
                .sorted { lhs, rhs in
                    let lhsSequence: Int = lhs["seqno"]
                    let rhsSequence: Int = rhs["seqno"]
                    return lhsSequence < rhsSequence
                }
                .map { row -> String in
                    let collation: String = row["coll"]
                    let isDescending: Int = row["desc"]
                    return "\(collation.lowercased())|\(isDescending)"
                }
        }

        for (tableName, expectedPrimaryKey) in SchemaValidationSpecification.primaryKeys {
            let tableInfo = try Row.fetchAll(database, sql: "PRAGMA table_info(\(tableName))")
            let actualPrimaryKey = tableInfo
                .compactMap { row -> (sequence: Int, name: String)? in
                    let sequence: Int = row["pk"]
                    guard sequence > 0 else { return nil }
                    let name: String = row["name"]
                    return (sequence, name)
                }
                .sorted { $0.sequence < $1.sequence }
                .map(\.name)
            guard actualPrimaryKey == expectedPrimaryKey else {
                throw LibraryDatabaseError.invalidSchema("Table \(tableName) has the wrong primary key")
            }

            var actualUniqueKeys: [[String]] = []
            for row in try Row.fetchAll(database, sql: "PRAGMA index_list(\(tableName))") {
                let isUnique: Int = row["unique"]
                guard isUnique == 1 else { continue }
                let indexName: String = row["name"]
                let columns = try indexColumns(named: indexName)
                let ordering = try indexOrdering(named: indexName)
                let expectedCollation = SchemaValidationSpecification.uniqueKeys[tableName]?
                    .first(where: { $0.columns == columns })?.collation ?? "binary"
                guard ordering == Array(repeating: "\(expectedCollation)|0", count: columns.count) else {
                    throw LibraryDatabaseError.invalidSchema("Index \(indexName) has the wrong ordering")
                }
                guard columns != expectedPrimaryKey else { continue }
                actualUniqueKeys.append(columns)
            }
            let expectedUniqueKeys = (SchemaValidationSpecification.uniqueKeys[tableName] ?? [])
                .map(\.columns)
                .sorted { $0.joined() < $1.joined() }
            actualUniqueKeys.sort { $0.joined() < $1.joined() }
            guard actualUniqueKeys == expectedUniqueKeys else {
                throw LibraryDatabaseError.invalidSchema("Table \(tableName) has the wrong unique keys")
            }
        }

        for (tableName, expectedForeignKeys) in SchemaValidationSpecification.foreignKeys {
            let actualForeignKeys = try Row.fetchAll(
                database,
                sql: "PRAGMA foreign_key_list(\(tableName))"
            ).map { row -> String in
                let from: String = row["from"]
                let table: String = row["table"]
                let destination: String = row["to"]
                let onDelete: String = row["on_delete"]
                return [from, table, destination, onDelete]
                    .map { $0.lowercased() }
                    .joined(separator: "|")
            }.sorted()
            let expected = expectedForeignKeys.map { foreignKey in
                [foreignKey.source, foreignKey.table, foreignKey.target, foreignKey.onDelete]
                    .map { $0.lowercased() }
                    .joined(separator: "|")
            }.sorted()
            guard actualForeignKeys == expected else {
                throw LibraryDatabaseError.invalidSchema("Table \(tableName) has the wrong foreign keys")
            }
        }

        for index in SchemaValidationSpecification.indexes {
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND name = ?",
                arguments: [index.name]
            ) else {
                throw LibraryDatabaseError.invalidSchema("Missing index \(index.name)")
            }
            let tableName: String = row["tbl_name"]
            guard tableName == index.table else {
                throw LibraryDatabaseError.invalidSchema("Index \(index.name) belongs to \(tableName)")
            }
            guard let indexMetadata = try Row.fetchAll(
                database,
                sql: "PRAGMA index_list(\(index.table))"
            ).first(where: { row in
                let name: String = row["name"]
                return name == index.name
            }) else {
                throw LibraryDatabaseError.invalidSchema("Missing index metadata \(index.name)")
            }
            let isPartial: Int = indexMetadata["partial"]
            guard isPartial == 0 else {
                throw LibraryDatabaseError.invalidSchema("Index \(index.name) must not be partial")
            }
            let createSQL: String? = row["sql"]
            let expectedPrefix = index.unique ? "create unique index" : "create index"
            guard let createSQL, normalizedSQL(createSQL).hasPrefix(expectedPrefix) else {
                throw LibraryDatabaseError.invalidSchema("Index \(index.name) has the wrong uniqueness")
            }
            let actualColumns = try indexColumns(named: index.name)
            guard actualColumns == index.columns else {
                throw LibraryDatabaseError.invalidSchema("Index \(index.name) has the wrong columns")
            }
            let actualOrdering = try indexOrdering(named: index.name)
            let expectedOrdering = Array(repeating: "\(index.collation)|0", count: index.columns.count)
            guard actualOrdering == expectedOrdering else {
                throw LibraryDatabaseError.invalidSchema("Index \(index.name) has the wrong ordering")
            }
        }

        guard let ftsSQL = try String.fetchOne(
            database,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'trackSearch'"
        ) else {
            throw LibraryDatabaseError.invalidSchema("Missing trackSearch")
        }
        let actualFTSColumns = Set(
            try Row.fetchAll(database, sql: "PRAGMA table_info(trackSearch)").map { row -> String in
                let name: String = row["name"]
                return name
            }
        )
        guard actualFTSColumns == ["searchText"] else {
            throw LibraryDatabaseError.invalidSchema("trackSearch has the wrong columns")
        }
        guard normalizedSQL(ftsSQL) == normalizedSQL(SchemaValidationSpecification.trackSearchDefinition) else {
            throw LibraryDatabaseError.invalidSchema("trackSearch has the wrong definition")
        }

        for trigger in SchemaValidationSpecification.triggers {
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = ?",
                arguments: [trigger.name]
            ) else {
                throw LibraryDatabaseError.invalidSchema("Missing trigger \(trigger.name)")
            }
            let createSQL: String = row["sql"]
            guard normalizedSQL(createSQL) == normalizedSQL(trigger.definition) else {
                throw LibraryDatabaseError.invalidSchema("Trigger \(trigger.name) has the wrong definition")
            }
        }
        let actualTriggerNames = try String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
        )
        let expectedTriggerNames = SchemaValidationSpecification.triggers.map(\.name).sorted()
        guard actualTriggerNames == expectedTriggerNames else {
            throw LibraryDatabaseError.invalidSchema("Unexpected trigger set")
        }
    }

    static func validateSchema(db database: Database) throws {
        try validateSchemaImplementation(database)
    }
}
