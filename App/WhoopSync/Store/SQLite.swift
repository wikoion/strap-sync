import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

/// A thin wrapper over the system SQLite: statements with bound values, rows as arrays, transactions.
final class SQLiteDB {
    enum Value: Equatable {
        case int(Int)
        case double(Double)
        case text(String)
        case blob([UInt8])
        case null

        var int: Int? { if case .int(let v) = self { return v }; return nil }
        var double: Double? {
            switch self {
            case .double(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }
        var text: String? { if case .text(let v) = self { return v }; return nil }
        var blob: [UInt8]? { if case .blob(let v) = self { return v }; return nil }
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(description: "open \(path) failed")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(description: msg)
        }
    }

    /// Runs one statement once per set of values. Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ rows: [[Value]] = [[]]) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var changed = 0
        for values in rows {
            try bind(stmt, values)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error(sql) }
            changed += Int(sqlite3_changes(db))
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        return changed
    }

    func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, values)
        var out: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(sql) }
            out.append((0..<sqlite3_column_count(stmt)).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob([]) }
                    return .blob(Array(UnsafeRawBufferPointer(start: p, count: n)))
                default: return .null
                }
            })
        }
        return out
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error(sql) }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let x): sqlite3_bind_int64(stmt, idx, Int64(x))
            case .double(let x): sqlite3_bind_double(stmt, idx, x)
            case .text(let x): sqlite3_bind_text(stmt, idx, x, -1, Self.transient)
            case .blob(let x): _ = x.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(x.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func error(_ sql: String) -> SQLiteError {
        SQLiteError(description: "\(String(cString: sqlite3_errmsg(db))) in: \(sql.prefix(60))")
    }
}
