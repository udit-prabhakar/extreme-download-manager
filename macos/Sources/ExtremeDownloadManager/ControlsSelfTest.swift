#if DEBUG
import Foundation

@MainActor
enum ControlsSelfTest {
    static func run(base: String, directory: URL) async throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw EngineError(message: message) } }
        func wait(_ store: DownloadStore, id: String, seconds: Double = 35, predicate: (DownloadItem) -> Bool) async throws -> DownloadItem {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                await store.refresh()
                if let item = store.items.first(where: { $0.id == id }) {
                    if predicate(item) { return item }
                    if item.status == "error" { throw EngineError(message: item.error) }
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            throw EngineError(message: "Timed out checking application transfer \(id). \(store.errorMessage ?? "")")
        }
        func discover(_ store: DownloadStore, gid: String) async throws -> DownloadItem {
            // A poll already in flight can predate a direct engine.add call.
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                await store.refresh()
                if let item = store.items.first(where: { $0.gid == gid }) { return item }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            throw EngineError(message: "Engine job \(gid) did not appear in the application. \(store.lastEngineError)")
        }
        // Exercise migration once, then prove an intentionally empty history stays empty.
        let migration = directory.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
        let legacy = DownloadItem(id: "legacy-id", name: "old.bin", source: base, directory: migration.path, status: "complete")
        try JSONEncoder().encode([legacy]).write(to: migration.appendingPathComponent("history.json"))
        var db: HistoryDatabase? = try HistoryDatabase(directory: migration)
        let imported = try await db!.load()
        try check(imported.count == 1 && imported[0].id == "legacy-id", "Legacy history migration failed")
        try await db!.write([]); db = nil
        let reopened = try HistoryDatabase(directory: migration)
        let empty = try await reopened.load()
        try check(empty.isEmpty, "Deleted legacy history reappeared after restart")
        print("PASS: transactional history migration preserves IDs and does not reimport deleted records")

        let store = DownloadStore(directory: directory.appendingPathComponent("controls"))
        store.preferences.directory = directory.appendingPathComponent("controlled-downloads").path
        store.preferences.autoStart = true
        store.preferences.concurrentDownloads = 1
        store.preferences.extra.uploadLimit = "64K"
        await store.start()
        do {
            try check(store.ready, "Application store failed to start: \(store.errorMessage ?? "")")
            // The same profile cannot launch a second owned engine.
            let competing = TransferEngine(dataDirectory: store.dataDirectory)
            var blocked = false
            do { try await competing.start(preferences: store.preferences) } catch { blocked = true }
            try check(blocked, "A second engine acquired the same profile")
            let competingStore = DownloadStore(directory: store.dataDirectory)
            await competingStore.start()
            try check(!competingStore.ready && competingStore.items.isEmpty, "A competing app loaded shared history without profile ownership")
            await competingStore.shutdown()
            print("PASS: profile lock prevents competing engines")

            var config = DownloadConfiguration.defaults(store.preferences)
            config.downloadLimit = "1M"; config.connections = 4; config.queue = "Regression"
            let added = await store.addURLs(base + "/payload.bin", directory: store.preferences.directory, filename: "repair.bin", configuration: config)
            try check(added, "Application could not add fixture: \(store.errorMessage ?? "")")
            let id = store.selection!
            let original = try await wait(store, id: id) { $0.completed > 4_000_000 }
            await store.perform("pause", item: original)
            let oldGID = original.gid
            let rejected = await store.repair(id, source: base + "/changed.bin", keepProgress: true)
            try check(!rejected, "Resource repair accepted a different file")
            store.errorMessage = nil
            let repaired = await store.repair(id, source: base + "/renewed.bin", keepProgress: true)
            try check(repaired, "Compatible link repair failed: \(store.errorMessage ?? "")")
            _ = try await wait(store, id: id, seconds: 55) { $0.status == "complete" }
            try check(store.items.first { $0.id == id }?.gid != oldGID, "Repair did not replace the engine job")
            try check(store.items.first { $0.id == id }?.configuration.queue == "Regression", "Repair lost queue configuration")
            await store.verifyChecksum(id)
            let expectedData = try await URLSession.shared.data(from: URL(string: base + "/expected-sha256")!).0
            let expected = String(decoding: expectedData, as: UTF8.self)
            try check(store.items.first { $0.id == id }?.verification?.contains(expected) == true, "Repaired file checksum did not match")
            print("PASS: expired-link repair retains stable app identity, refuses changed content, and completes with the correct hash")

            config.downloadLimit = "0"; config.scheduledAt = Date().addingTimeInterval(600)
            let scheduled = await store.addURLs(base + "/payload.bin", directory: store.preferences.directory, filename: "scheduled.bin", configuration: config)
            try check(scheduled, "Could not add scheduled transfer")
            let scheduledID = store.selection!
            let paused = try await wait(store, id: scheduledID) { $0.status == "paused" }
            try check(paused.completed == 0 && paused.configuration.scheduledAt != nil, "Scheduled transfer started prematurely")
            await store.runScheduled(now: Date().addingTimeInterval(700))
            _ = try await wait(store, id: scheduledID) { $0.status == "complete" }
            print("PASS: scheduled transfer stays paused until due and then completes")

            let recoveryAdded = await store.addURLs(base + "/payload.bin", directory: store.preferences.directory, filename: "scheduled-recovery.bin", configuration: config)
            try check(recoveryAdded, "Could not add scheduled recovery fixture")
            let recoveryID = store.selection!
            let recovery = try await wait(store, id: recoveryID) { $0.status == "paused" }
            _ = try await store.engine.call("forceRemove", [recovery.gid])
            // Removal is asynchronous; a missing result is also an acceptable missing-job fixture.
            for _ in 0..<40 {
                let raw = try? await store.engine.call("tellStatus", [recovery.gid]) as? [String: Any]
                if raw == nil || raw?["status"] as? String == "removed" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = try? await store.engine.call("removeDownloadResult", [recovery.gid])
            await store.runScheduled(now: Date().addingTimeInterval(700))
            _ = try await wait(store, id: recoveryID) { $0.status == "complete" && $0.configuration.scheduledAt == nil }
            print("PASS: due scheduled download recovers a missing engine job and clears its schedule")

            let (multi, _) = try await URLSession.shared.data(from: URL(string: base + "/multi.torrent")!)
            var pausedPreferences = store.preferences; pausedPreferences.autoStart = false
            let multiID = try await store.engine.add(source: "multi.torrent", directory: store.preferences.directory, filename: nil, preferences: pausedPreferences, torrent: multi.base64EncodedString())
            let multiItem = try await discover(store, gid: multiID)
            await store.inspect(multiItem.id)
            var chosen = multiItem.configuration; chosen.selectedFiles = [1]; chosen.uploadLimit = "32K"; chosen.seedMode = .stop
            let saved = await store.saveControls(chosen, id: multiItem.id)
            try check(saved, "Could not apply torrent controls: \(store.errorMessage ?? "")")
            let files = try await store.engine.call("getFiles", [multiID]) as? [[String: Any]] ?? []
            try check(files.count == 2 && files[0]["selected"] as? String == "true" && files[1]["selected"] as? String == "false", "Torrent file selection did not reach the engine")
            let options = try await store.engine.call("getOption", [multiID]) as? [String: String] ?? [:]
            try check(options["max-upload-limit"] == "32768" || options["max-upload-limit"] == "32K", "Per-torrent upload limit was not set")
            chosen.sequential = true
            let prioritize = await store.saveControls(chosen, id: multiItem.id)
            try check(prioritize, "Could not enable media piece prioritization")
            chosen.sequential = false
            let resetPriority = await store.saveControls(chosen, id: multiItem.id)
            let resetOptions = try await store.engine.call("getOption", [multiID]) as? [String: String] ?? [:]
            try check(resetPriority && resetOptions["stream-piece-selector"] == "default" && resetOptions["bt-prioritize-piece"] == "", "Media piece priority did not reset")
            print("PASS: torrent file selection and per-torrent upload limits are enforced by engine options")

            // Seed known local bytes and ask a controlled local peer to receive them.
            let payload = directory.appendingPathComponent("downloads/first.bin")
            let fixture = URL(fileURLWithPath: store.preferences.directory).appendingPathComponent("fixture.bin")
            try FileManager.default.copyItem(at: payload, to: fixture)
            let torrent = try await URLSession.shared.data(from: URL(string: base + "/fixture.torrent")!).0
            var sharing = DownloadConfiguration.defaults(store.preferences); sharing.seedMode = .ratio; sharing.seedRatio = 2; sharing.uploadLimit = "64K"
            let seedGID = try await store.engine.add(source: "fixture.torrent", directory: store.preferences.directory, filename: nil, preferences: store.preferences, torrent: torrent.base64EncodedString(), configuration: sharing)
            let seed = try await discover(store, gid: seedGID)
            if let index = store.items.firstIndex(where: { $0.id == seed.id }) {
                store.items[index].configuration = sharing
                store.items[index].torrentData = torrent.base64EncodedString()
                store.items[index].source = base + "/fixture.torrent"
            }
            _ = try await wait(store, id: seed.id) { $0.status == "active" && $0.completed == $0.total && $0.total > 0 }
            var request = URLRequest(url: URL(string: base + "/upload-check?port=\(store.engine.peerPort)")!); request.timeoutInterval = 75
            let reply = try await URLSession.shared.data(for: request).0
            let upload = try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
            try check(upload["error"] == nil, "Local upload peer failed: \(upload["error"] ?? "unknown")")
            try check(upload["bytes"] as? Int == 512 * 1024, "Local peer did not receive the expected data")
            try check((upload["bytes_per_second"] as? Double ?? .infinity) < 131072, "Upload cap was not observed")
            _ = try await wait(store, id: seed.id) { ($0.uploadedBytes ?? 0) >= 512 * 1024 }
            print("PASS: real local torrent upload, cap, seeding policy, and uploaded-byte accounting (\(upload))")
            if let current = store.items.first(where: { $0.id == seed.id }) {
                var stop = current.configuration; stop.seedMode = .stop
                let stopped = await store.saveControls(stop, id: current.id)
                try check(stopped, "Could not switch to stop-after-completion: \(store.errorMessage ?? "")")
                _ = try await wait(store, id: current.id) { $0.status == "complete" }
            }
            print("PASS: changing seed policy stops completed-torrent sharing")
            try await BrowserSelfTest.run(base: base, store: store, directory: directory)
            store.persist(); await store.flushPersistence()
            await store.shutdown()
            let savedDB = try HistoryDatabase(directory: store.dataDirectory)
            let savedItems = try await savedDB.load()
            try check(savedItems.contains { $0.id == id && $0.status == "complete" && $0.configuration.queue == "Regression" }, "Application database did not retain the repaired download")
            print("PASS: application history persists stable IDs and per-download controls")
            let restored = DownloadStore(directory: store.dataDirectory)
            await restored.start()
            try check(restored.ready && restored.items.contains { $0.id == id && $0.status == "complete" }, "Completed application history changed after reopening")
            try check(restored.items.contains { $0.id == multiItem.id && $0.configuration.selectedFiles == [1] }, "Torrent file choices were lost after reopening")
            await restored.shutdown()
            print("PASS: reopening the app retains completed history and torrent file choices")

            let legacyDirectory = directory.appendingPathComponent("legacy-retry")
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            let legacyFailed = DownloadItem(id: "legacy-failed-id", name: "legacy-retry.bin", source: base + "/payload.bin", directory: legacyDirectory.path, status: "error")
            try JSONEncoder().encode([legacyFailed]).write(to: legacyDirectory.appendingPathComponent("history.json"))
            let legacyStore = DownloadStore(directory: legacyDirectory)
            await legacyStore.start()
            guard let failed = legacyStore.items.first else { throw EngineError(message: "Legacy retry history was not loaded") }
            await legacyStore.perform("resume", item: failed)
            _ = try await wait(legacyStore, id: legacyFailed.id) { $0.status == "complete" }
            await legacyStore.shutdown()
            print("PASS: a failed legacy download retries successfully without changing its application ID")
        } catch { await store.shutdown(); throw error }
    }
}

#endif
