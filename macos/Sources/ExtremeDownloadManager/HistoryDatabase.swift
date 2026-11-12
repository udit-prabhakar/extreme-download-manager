import Foundation
import CSQLite

/// Serializes durable state off the UI actor; SQLite transactions preserve the previous snapshot on failure.
actor HistoryDatabase {
    private var handle: OpaquePointer?
    private let directory: URL
    private var saved: [String: Data] = [:]
    private var loaded = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("history.sqlite")
        var opened: OpaquePointer?
        guard sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(opened); throw EngineError(message: "Could not open download history. Its files were left in place.") }
        do {
            guard let opened else { throw EngineError(message: "Could not open download history.") }
            let version = try Self.scalar(opened, "PRAGMA user_version")
            guard let number = Int(version), (0...1).contains(number) else { throw EngineError(message: "This history uses a newer or unsupported schema. Install the matching app version; this app will not downgrade or overwrite it.") }
            guard try Self.scalar(opened, "PRAGMA quick_check") == "ok" else { throw EngineError(message: "Download history failed its integrity check. Open Engine & storage to restore a backup; the original files were kept.") }
            sqlite3_busy_timeout(opened, 5000)
            for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, record BLOB NOT NULL)", "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)", "PRAGMA user_version=1"] {
                guard sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK else { throw EngineError(message: "Could not initialize download history. Check free disk space and folder permissions.") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            handle = opened
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }
    func close() { sqlite3_close(handle); handle = nil }

    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { throw EngineError(message: "History is unreadable. Its files were preserved; open Engine & storage for recovery.") }
        defer { sqlite3_finalize(query) }
        let step = sqlite3_step(query)
        guard step == SQLITE_ROW, let text = sqlite3_column_text(query, 0) else { throw EngineError(message: "Could not read history metadata: \(String(cString: sqlite3_errmsg(db))) (\(step)). The existing files were kept.") }
        return String(cString: text)
    }

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
        let importStep = sqlite3_step(imported)
        sqlite3_finalize(imported)
        guard importStep == SQLITE_ROW || importStep == SQLITE_DONE else { throw EngineError(message: "Could not read history migration state.") }
        let needsImport = importStep == SQLITE_DONE
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
        var records: [String: Data] = [:]
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            guard let id = sqlite3_column_text(query, 0), let blob = sqlite3_column_blob(query, 1) else { throw EngineError(message: "A download history record is unreadable.") }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(query, 1)))
            let item = try JSONDecoder().decode(DownloadItem.self, from: data)
            guard item.id == String(cString: id), !item.id.isEmpty else { throw EngineError(message: "History contains an invalid transfer identity. Its files were kept for recovery.") }
            records[item.id] = data
            result.append(item)
            step = sqlite3_step(query)
        }
        guard step == SQLITE_DONE else { throw EngineError(message: "Reading history was interrupted. No records were discarded.") }
        guard Set(result.map(\.gid)).count == result.count else { throw EngineError(message: "History contains duplicate engine identities. Its files were kept for recovery.") }
        saved = records; loaded = true
        if !result.isEmpty { try backupIfNeeded() }
        return result.sorted { $0.added > $1.added }
    }

    func write(_ items: [DownloadItem]) throws {
        guard Set(items.map(\.gid)).count == items.count else { throw EngineError(message: "Duplicate engine identity; the previous history was retained.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var current: [String: Data] = [:]
        for item in items {
            guard !item.id.isEmpty, current[item.id] == nil else { throw EngineError(message: "Duplicate or empty download identity; the previous history was retained.") }
            current[item.id] = try encoder.encode(item)
        }
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
        if loaded && !items.isEmpty { try backupIfNeeded() }
    }

    private func backupIfNeeded() throws {
        let backup = directory.appendingPathComponent("history-backup.sqlite")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: backup.path), let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 3600 { return }
        let temporary = directory.appendingPathComponent("history-backup-\(UUID().uuidString).tmp")
        var destination: OpaquePointer?
        defer { sqlite3_close(destination); try? FileManager.default.removeItem(at: temporary) }
        guard sqlite3_open_v2(temporary.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw EngineError(message: "Could not create a history backup. Check free disk space.") }
        guard let copy = sqlite3_backup_init(destination, "main", handle, "main") else { throw EngineError(message: "Could not begin a consistent history backup.") }
        let step = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard step == SQLITE_DONE && finish == SQLITE_OK else { throw EngineError(message: "History backup could not finish. The previous backup was retained.") }
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw EngineError(message: "History backup could not be made standalone. The previous backup was retained.") }
        sqlite3_close(destination); destination = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: backup.path) { _ = try FileManager.default.replaceItemAt(backup, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: backup) }
    }

    /// Call only while the app owns the profile lock and has closed the live database.
    static func restoreBackup(directory: URL) throws -> URL {
        let backup = directory.appendingPathComponent("history-backup.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); throw EngineError(message: "No readable history backup is available.") }
        do {
            guard let db, try scalar(db, "PRAGMA user_version") == "1", try scalar(db, "PRAGMA quick_check") == "ok", try scalar(db, "SELECT value FROM metadata WHERE key='legacy_imported'") == "1" else { throw EngineError(message: "The backup is incompatible or damaged. Current history was left unchanged.") }
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, record FROM downloads", -1, &query, nil) == SQLITE_OK else { throw EngineError(message: "The backup has no valid download table.") }
            defer { sqlite3_finalize(query) }
            var step = sqlite3_step(query), ids = Set<String>(), gids = Set<String>()
            while step == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(query, 1), let id = sqlite3_column_text(query, 0) else { throw EngineError(message: "The backup contains unreadable records.") }
                let item = try JSONDecoder().decode(DownloadItem.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 1))))
                guard item.id == String(cString: id), !item.id.isEmpty, ids.insert(item.id).inserted, gids.insert(item.gid).inserted else { throw EngineError(message: "The backup contains invalid transfer identities.") }
                step = sqlite3_step(query)
            }
            guard step == SQLITE_DONE else { throw EngineError(message: "The backup could not be fully read.") }
        } catch { sqlite3_close(db); throw error }
        sqlite3_close(db)
        let temporary = directory.appendingPathComponent("restored-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: backup, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let preserved = directory.appendingPathComponent("Preserved history/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var moved: [String] = []
        do {
            for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
                let original = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: original, to: preserved.appendingPathComponent(name)); moved.append(name) }
            }
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent("history.sqlite"))
        } catch {
            for name in moved.reversed() { try? FileManager.default.moveItem(at: preserved.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
            throw error
        }
        return preserved
    }

    func save(_ items: [DownloadItem], preferences: AppPreferences) throws {
        try write(items)
        let data = try JSONEncoder().encode(preferences)
        let file = directory.appendingPathComponent("preferences.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
