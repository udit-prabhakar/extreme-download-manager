#if DEBUG
import Foundation
import Darwin
import CSQLite

@MainActor
enum HardeningSelfTest {
    static func storage(base: String, directory: URL) async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw EngineError(message: message) } }
        let storage = directory.appendingPathComponent("storage-hardening")
        var database: HistoryDatabase? = try HistoryDatabase(directory: storage)
        _ = try await database!.load()
        let record = DownloadItem(id: "backup-record", name: "retained.bin", source: base, directory: directory.path, status: "complete")
        try await database!.write([record])
        var duplicateRejected = false
        do { try await database!.write([record, record]) } catch { duplicateRejected = true }
        try check(duplicateRejected, "Duplicate history write did not fail safely")
        var duplicateEngine = record; duplicateEngine.id = "another-record"; duplicateEngine.engineID = record.gid
        duplicateRejected = false
        do { try await database!.write([record, duplicateEngine]) } catch { duplicateRejected = true }
        try check(duplicateRejected, "Duplicate engine identity was saved")
        let intact = try await database!.load()
        try check(intact.count == 1, "Rejected history write changed existing records")
        await database!.close(); database = nil
        let file = storage.appendingPathComponent("history.sqlite")
        let damaged = Data("intentionally damaged local database".utf8)
        try damaged.write(to: file)
        var refused = false
        do { _ = try HistoryDatabase(directory: storage) } catch { refused = true }
        try check(refused && (try Data(contentsOf: file)) == damaged, "Corrupt history was changed instead of preserved")
        let preserved = try HistoryDatabase.restoreBackup(directory: storage)
        try check(try Data(contentsOf: preserved.appendingPathComponent("history.sqlite")) == damaged, "Restore did not preserve the damaged original")
        let restored = try HistoryDatabase(directory: storage)
        let records = try await restored.load()
        try check(records.map(\.id) == [record.id], "Restored backup did not retain history")

        let future = directory.appendingPathComponent("future-history")
        try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
        let futureFile = future.appendingPathComponent("history.sqlite")
        var raw: OpaquePointer?
        guard sqlite3_open(futureFile.path, &raw) == SQLITE_OK else { throw EngineError(message: "Could not create future-schema fixture") }
        let created = sqlite3_exec(raw, "PRAGMA user_version=99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES ('keep');", nil, nil, nil)
        sqlite3_close(raw)
        try check(created == SQLITE_OK, "Could not create future-schema fixture")
        let original = try Data(contentsOf: futureFile)
        refused = false
        do { _ = try HistoryDatabase(directory: future) } catch { refused = error.localizedDescription.contains("newer") }
        try check(refused && (try Data(contentsOf: futureFile)) == original, "Opening newer history changed its schema or contents")
        print("PASS: duplicate writes and corrupt/newer history fail safely; consistent backup restore preserves the damaged originals")
    }

    static func run(base: String, directory: URL) async throws {
        try await storage(base: base, directory: directory)
        func check(_ value: Bool, _ message: String) throws { if !value { throw EngineError(message: message) } }
        let store = DownloadStore(directory: directory.appendingPathComponent("crash-recovery"))
        store.preferences.directory = directory.appendingPathComponent("crash-downloads").path
        store.preferences.autoStart = true
        await store.start()
        do {
            try check(store.ready, "Crash recovery store did not start")
            var noStart = store.preferences; noStart.autoStart = false
            var unpinnedRejected = false
            do { _ = try await store.engine.add(source: "sftp://127.0.0.1:9/fixture", directory: store.preferences.directory, filename: nil, preferences: noStart) } catch { unpinnedRejected = true }
            try check(unpinnedRejected, "SFTP without host-key validation was accepted")
            var pinned = DownloadConfiguration(); pinned.sshHostKeySHA1 = String(repeating: "ab:", count: 19) + "ab"
            let sftp = try await store.engine.add(source: "sftp://127.0.0.1:9/fixture", directory: store.preferences.directory, filename: nil, preferences: noStart, configuration: pinned)
            let sshOptions = try await store.engine.call("getOption", [sftp]) as? [String: String] ?? [:]
            try check(sshOptions["ssh-host-key-md"] == "sha-1=" + String(repeating: "ab", count: 20), "SSH fingerprint did not reach the engine")
            _ = try await store.engine.call("forceRemove", [sftp])
            _ = try? await store.engine.call("removeDownloadResult", [sftp])
            print("PASS: unpinned SFTP is refused and a supplied host-key fingerprint reaches a paused engine job without network access")
            if ProcessInfo.processInfo.environment["EDM_ARIA2_PATH"]?.contains("Extreme Download Manager.app") == true {
                let malformed = Data("d4:infod6:lengthi1e4:name11:fixture.bin12:piece lengthi0e6:pieces20:xxxxxxxxxxxxxxxxxxxxee".utf8)
                var rejected = false
                do { _ = try await store.engine.add(source: "zero-piece.torrent", directory: store.preferences.directory, filename: nil, preferences: store.preferences, torrent: malformed.base64EncodedString()) } catch { rejected = true }
                _ = try await store.engine.call("getVersion")
                try check(rejected && store.engine.running, "Malformed torrent metadata crashed the bundled RPC engine")
                print("PASS: bundled RPC engine rejects zero-piece metadata and remains healthy")
            }
            var config = DownloadConfiguration(); config.downloadLimit = "512K"; config.connections = 2
            let added = await store.addURLs(base + "/payload.bin", directory: store.preferences.directory, filename: "crash.bin", configuration: config)
            try check(added, "Could not add crash fixture")
            let id = store.selection!
            store.preferences.autoStart = false
            let pausedAdded = await store.addURLs(base + "/renewed.bin", directory: store.preferences.directory, filename: "keep-paused.bin")
            try check(pausedAdded, "Could not add paused recovery fixture")
            let pausedID = store.selection!
            store.preferences.autoStart = true
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                await store.refresh()
                if store.items.first(where: { $0.id == id })?.completed ?? 0 > 2_000_000 { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try check((store.items.first { $0.id == id }?.completed ?? 0) > 2_000_000, "Crash fixture did not reach its partial-progress checkpoint")
            guard let pid = store.engine.processID else { throw EngineError(message: "Owned engine PID unavailable") }
            try check(kill(pid, SIGKILL) == 0, "Could not terminate the owned engine fixture")
            let recoveryDeadline = Date().addingTimeInterval(30)
            while Date() < recoveryDeadline {
                await store.refresh()
                if store.ready && store.engine.processID != nil && store.engine.processID != pid { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try check(store.ready && store.engine.processID != pid && store.engine.processID != nil, "Automatic engine crash recovery failed: " + store.lastEngineError)
            guard let recovered = store.items.first(where: { $0.id == id }) else { throw EngineError(message: "Crash recovery changed the app download ID") }
            var fast = recovered.configuration; fast.downloadLimit = "0"
            let applied = await store.saveControls(fast, id: id)
            try check(applied, "Could not change recovered download limit")
            let finishDeadline = Date().addingTimeInterval(40)
            while Date() < finishDeadline {
                await store.refresh()
                if let item = store.items.first(where: { $0.id == id }), item.status == "complete", item.quarantineApplied != nil { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try check(store.items.first(where: { $0.id == id })?.status == "complete", "Recovered download did not complete")
            let expected = try await URLSession.shared.data(from: URL(string: base + "/expected-sha256")!).0
            let actual = try TransferUtilities.sha256(URL(fileURLWithPath: store.preferences.directory).appendingPathComponent("crash.bin"))
            try check(actual == String(decoding: expected, as: UTF8.self), "Crash recovery output checksum mismatch")
            let completedURL = URL(fileURLWithPath: store.preferences.directory).appendingPathComponent("crash.bin")
            try check(store.items.first(where: { $0.id == id })?.quarantineApplied == true && (try completedURL.resourceValues(forKeys: [.quarantinePropertiesKey])).quarantineProperties != nil, "Completed output did not receive macOS quarantine metadata")
            print("PASS: completed output retains correct bytes and receives macOS quarantine metadata")
            try check(store.items.first(where: { $0.id == pausedID })?.status == "paused", "Crash recovery resumed a user-paused job")
            print("PASS: owned engine SIGKILL recovers automatically; active transfer keeps its ID and completes correctly while paused transfer stays paused")

            let savedOverride = ProcessInfo.processInfo.environment["EDM_ARIA2_PATH"]
            setenv("EDM_ARIA2_PATH", "/usr/bin/false", 1)
            defer { if let savedOverride { setenv("EDM_ARIA2_PATH", savedOverride, 1) } else { unsetenv("EDM_ARIA2_PATH") } }
            for _ in 0..<3 { await store.recoverEngine() }
            try check(!store.ready && store.engineMessage.contains("Recovery stopped"), "Failed recovery attempts were not capped")
            let competing = TransferEngine(dataDirectory: store.dataDirectory)
            var locked = false
            do { try await competing.start(preferences: store.preferences) } catch { locked = true }
            try check(locked, "Profile lock was released during failed recovery")
            if let savedOverride { setenv("EDM_ARIA2_PATH", savedOverride, 1) } else { unsetenv("EDM_ARIA2_PATH") }
            await store.recoverEngine(manual: true)
            try check(store.ready, "Manual retry did not recover after the startup problem was fixed")
            await store.shutdown()
            try check(!FileManager.default.fileExists(atPath: store.dataDirectory.appendingPathComponent("engine.conf").path), "Shutdown retained private runtime configuration")
            print("PASS: failed recovery is bounded, retains profile ownership, supports manual retry, and cleans up runtime secrets")
        } catch { await store.shutdown(); throw error }
    }
}

#endif
