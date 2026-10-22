import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case failure(String)
    var errorDescription: String? {
        switch self { case .failure(let message): message }
    }
}

/// Never creates, migrates, checkpoints, or writes the provider's database.
final class ReadOnlyDatabase {
    private var handle: OpaquePointer?
    init(path: String) throws {
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw DatabaseError.failure(message)
        }
        sqlite3_busy_timeout(handle, 150)
    }
    deinit { if let handle { sqlite3_close(handle) } }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.failure(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else {
                throw DatabaseError.failure(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, i) != SQLITE_NULL {
                if let name = sqlite3_column_name(statement, i), let value = sqlite3_column_text(statement, i) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }

    func columns(_ table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] })
    }
    func tables() throws -> Set<String> {
        Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
    }
}

func sqlLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
