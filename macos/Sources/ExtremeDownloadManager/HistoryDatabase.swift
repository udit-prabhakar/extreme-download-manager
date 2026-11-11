import Foundation
import CSQLite

/// Serializes durable state off the UI actor; SQLite transactions preserve the previous snapshot on failure.
actor HistoryDatabase {
    private var handle: OpaquePointer?
    private let directory: URL
    private var saved: [String: Data] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("history.sqlite")
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw EngineError(message: "Could not open the download history database.") }
        sqlite3_busy_timeout(handle, 5000)
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, record BLOB NOT NULL)", "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)", "PRAGMA user_version=1"] {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw EngineError(message: "Could not initialize the download history database.") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    deinit { sqlite3_close(handle) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw EngineError(message: "History transaction failed: \(String(cString: sqlite3_errmsg(handle)))") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw EngineError(message: "Could not prepare a history query.") }
        return statement
    }

    func load() throws -> [DownloadItem] {
        let imported = try prepare("SELECT value FROM metadata WHERE key='legacy_imported'")
        let needsImport = sqlite3_step(imported) != SQLITE_ROW
        sqlite3_finalize(imported)
        if needsImport {
            let legacy = directory.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                let data = try Data(contentsOf: legacy)
                let items = try JSONDecoder().decode([DownloadItem].self, from: data)
                let backup = directory.appendingPathComponent("history-v1-backup.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path) }
                try write(items)
            }
            try execute("INSERT OR REPLACE INTO metadata VALUES ('legacy_imported', '1')")
        }
        let query = try prepare("SELECT id, record FROM downloads")
        defer { sqlite3_finalize(query) }
        var result: [DownloadItem] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let id = sqlite3_column_text(query, 0), let blob = sqlite3_column_blob(query, 1) else { throw EngineError(message: "A download history record is unreadable.") }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(query, 1)))
            let item = try JSONDecoder().decode(DownloadItem.self, from: data)
            saved[String(cString: id)] = data
            result.append(item)
        }
        return result.sorted { $0.added > $1.added }
    }

    func write(_ items: [DownloadItem]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let current = try Dictionary(uniqueKeysWithValues: items.map { ($0.id, try encoder.encode($0)) })
        let upsert = try prepare("INSERT INTO downloads(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record=excluded.record")
        let remove = try prepare("DELETE FROM downloads WHERE id=?")
        defer { sqlite3_finalize(upsert); sqlite3_finalize(remove) }
        try execute("BEGIN IMMEDIATE")
        do {
            for (id, data) in current where saved[id] != data {
                sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
                sqlite3_bind_text(upsert, 1, id, -1, transient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(upsert, 2, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw EngineError(message: "Could not save a download history record.") }
            }
            for id in saved.keys where current[id] == nil {
                sqlite3_reset(remove); sqlite3_bind_text(remove, 1, id, -1, transient)
                guard sqlite3_step(remove) == SQLITE_DONE else { throw EngineError(message: "Could not remove a download history record.") }
            }
            try execute("COMMIT")
            saved = current
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func save(_ items: [DownloadItem], preferences: AppPreferences) throws {
        try write(items)
        let data = try JSONEncoder().encode(preferences)
        let file = directory.appendingPathComponent("preferences.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
