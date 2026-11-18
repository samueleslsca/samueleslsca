import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum RecordKind: String, Codable, CaseIterable, Sendable {
    case speedTest, event, healthSample, wifiSample, deviceInventory, auditLog, heatmapProject
    case ispProfile, bufferbloatReport, multipointRun, gamingRun, dnsBenchmark, diagnosticReport, networkProfile
    case boostSession, boostChange
}

public enum HistoryStoreError: Error, LocalizedError {
    case open(String), prepare(String), step(String), decode(String)
    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Ouverture de l’historique impossible : \(m)"
        case .prepare(let m), .step(let m): return "Erreur SQLite : \(m)"
        case .decode(let m): return "Enregistrement illisible : \(m)"
        }
    }
}

/// Local SQLite history. Payloads are JSON-encoded Codable values; key columns allow time-range queries.
/// Thread-safe through a serial lock. All data stays on this Mac.
public final class HistoryStore: @unchecked Sendable {
    public let url: URL?
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// Set when an existing database failed its integrity check and was moved aside.
    public private(set) var recoveredFromCorruption: URL?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    /// - Parameter url: database file; `nil` → in-memory (tests, previews).
    public init(url: URL?) throws {
        self.url = url
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try openDatabase()
        if let url, !(try integrityOK()) {
            sqlite3_close(db); db = nil
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            recoveredFromCorruption = aside
            try openDatabase()
        }
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func openDatabase() throws {
        let path = url?.path ?? ":memory:"
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "inconnue"
            sqlite3_close(handle)
            throw HistoryStoreError.open(msg)
        }
        db = handle
        sqlite3_busy_timeout(db, 2000)
    }

    private func integrityOK() throws -> Bool {
        var ok = false
        do {
            try query("PRAGMA quick_check", bind: { _ in }) { stmt in
                if let c = sqlite3_column_text(stmt, 0), String(cString: c) == "ok" { ok = true }
            }
        } catch { return false }
        return ok
    }

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS records (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              ts REAL NOT NULL,
              network TEXT,
              payload BLOB NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_records_kind_ts ON records(kind, ts)")
        try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1')")
    }

    // MARK: Public API

    public func save<T: Encodable>(_ value: T, kind: RecordKind, id: String = UUID().uuidString,
                                   timestamp: Date = Date(), network: String? = nil) throws {
        let data = try Self.encoder.encode(value)
        try withLock {
            try run("INSERT OR REPLACE INTO records(id, kind, ts, network, payload) VALUES (?,?,?,?,?)") { s in
                bindText(s, 1, id); bindText(s, 2, kind.rawValue)
                sqlite3_bind_double(s, 3, timestamp.timeIntervalSince1970)
                if let n = network { bindText(s, 4, n) } else { sqlite3_bind_null(s, 4) }
                _ = data.withUnsafeBytes { p in sqlite3_bind_blob(s, 5, p.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
            }
        }
    }

    /// Loads records of a kind in a time range. Unreadable rows are skipped and counted in `skipped`.
    public func load<T: Decodable>(_ type: T.Type, kind: RecordKind, from: Date = .distantPast, to: Date = .distantFuture,
                                   network: String? = nil, limit: Int = 10_000) throws -> (items: [T], skipped: Int) {
        var items: [T] = []
        var skipped = 0
        var sql = "SELECT payload FROM records WHERE kind = ? AND ts >= ? AND ts <= ?"
        if network != nil { sql += " AND network = ?" }
        sql += " ORDER BY ts ASC LIMIT ?"
        try withLock {
            try query(sql, bind: { s in
                bindText(s, 1, kind.rawValue)
                sqlite3_bind_double(s, 2, max(from.timeIntervalSince1970, -1e12))
                sqlite3_bind_double(s, 3, min(to.timeIntervalSince1970, 1e12))
                var i: Int32 = 4
                if let n = network { bindText(s, i, n); i += 1 }
                sqlite3_bind_int64(s, i, Int64(limit))
            }) { s in
                let n = Int(sqlite3_column_bytes(s, 0))
                guard let p = sqlite3_column_blob(s, 0), n > 0 else { skipped += 1; return }
                let data = Data(bytes: p, count: n)
                if let v = try? Self.decoder.decode(T.self, from: data) { items.append(v) } else { skipped += 1 }
            }
        }
        return (items, skipped)
    }

    public func loadOne<T: Decodable>(_ type: T.Type, kind: RecordKind, id: String) throws -> T? {
        var result: T?
        try withLock {
            try query("SELECT payload FROM records WHERE kind = ? AND id = ?", bind: { s in
                bindText(s, 1, kind.rawValue); bindText(s, 2, id)
            }) { s in
                let n = Int(sqlite3_column_bytes(s, 0))
                guard let p = sqlite3_column_blob(s, 0), n > 0 else { return }
                result = try? Self.decoder.decode(T.self, from: Data(bytes: p, count: n))
            }
        }
        return result
    }

    public func count(kind: RecordKind) throws -> Int {
        var c = 0
        try withLock {
            try query("SELECT COUNT(*) FROM records WHERE kind = ?", bind: { bindText($0, 1, kind.rawValue) }) {
                c = Int(sqlite3_column_int64($0, 0))
            }
        }
        return c
    }

    public func delete(id: String) throws {
        try withLock { try run("DELETE FROM records WHERE id = ?") { bindText($0, 1, id) } }
    }

    /// Retention: deletes records of `kind` older than `date`. Returns deleted row count.
    @discardableResult
    public func purge(kind: RecordKind, olderThan date: Date) throws -> Int {
        var changes = 0
        try withLock {
            try run("DELETE FROM records WHERE kind = ? AND ts < ?") { s in
                bindText(s, 1, kind.rawValue); sqlite3_bind_double(s, 2, date.timeIntervalSince1970)
            }
            changes = Int(sqlite3_changes(db))
        }
        return changes
    }

    /// Erases all local history (Settings → "Effacer l’historique").
    public func eraseAll() throws {
        try withLock { try exec("DELETE FROM records"); try exec("VACUUM") }
    }

    // MARK: SQLite plumbing

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ s: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT)
    }

    private func withLock(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try body()
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "inconnue"
            sqlite3_free(err)
            throw HistoryStoreError.step(m)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw HistoryStoreError.prepare(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw HistoryStoreError.step(String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) throws -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw HistoryStoreError.prepare(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(s) }
        bind(s)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try row(s) } else if rc == SQLITE_DONE { break }
            else { throw HistoryStoreError.step(String(cString: sqlite3_errmsg(db))) }
        }
    }
}
