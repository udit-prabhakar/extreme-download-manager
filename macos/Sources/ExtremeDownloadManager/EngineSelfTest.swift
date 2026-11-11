import Foundation
import CryptoKit

/// Real transfer integration test, activated only by the explicit CLI flag.
@MainActor
enum EngineSelfTest {
    static func run() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--test-url"), arguments.count > index + 1,
              let root = ProcessInfo.processInfo.environment["EDM_DATA_DIR"] else {
            fputs("Self-test requires --test-url and EDM_DATA_DIR.\n", stderr); exit(2)
        }
        let base = arguments[index + 1]
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        var engine = TransferEngine(dataDirectory: directory.appendingPathComponent("engine"))
        let downloads = directory.appendingPathComponent("downloads")
        var settings = AppPreferences()
        settings.directory = downloads.path; settings.concurrentDownloads = 1; settings.connections = 4; settings.speedLimit = "1M"
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw EngineError(message: message) }
        }
        func status(_ engine: TransferEngine, _ gid: String) async throws -> [String: Any] {
            try await engine.call("tellStatus", [gid]) as? [String: Any] ?? [:]
        }
        func waitFor(_ engine: TransferEngine, _ gid: String, timeout: Double = 20, _ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let value = try await status(engine, gid)
                if predicate(value) { return value }
                if value["status"] as? String == "error" { throw EngineError(message: "Transfer failed: \(value["errorMessage"] ?? "unknown")") }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            throw EngineError(message: "Timed out waiting for \(gid)")
        }
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try await engine.start(preferences: settings)
            let version = try await engine.call("getVersion")
            print("PASS: isolated download engine starts: \(version)")
            let first = try await engine.add(source: base + "/payload.bin", directory: downloads.path, filename: "first.bin", preferences: settings)
            let second = try await engine.add(source: base + "/payload.bin", directory: downloads.path, filename: "queued.bin", preferences: settings)
            let progress = try await waitFor(engine, first) { (Int64($0["completedLength"] as? String ?? "0") ?? 0) > 4_000_000 }
            try require(progress["status"] as? String == "active", "First transfer is not active")
            let queued = try await status(engine, second)
            try require(queued["status"] as? String == "waiting", "Concurrency limit did not queue the second transfer")
            print("PASS: actual transfer and concurrency queue")
            _ = try await engine.call("forcePause", [first])
            let paused = try await waitFor(engine, first) { $0["status"] as? String == "paused" }
            let pausedBytes = Int64(paused["completedLength"] as? String ?? "0") ?? 0
            try require(pausedBytes > 0, "Pause lost progress")
            print("PASS: pause retains \(pausedBytes) bytes")
            await engine.shutdown()
            engine = TransferEngine(dataDirectory: directory.appendingPathComponent("engine"))
            try await engine.start(preferences: settings)
            let restored = try await status(engine, first)
            try require(restored["status"] as? String == "paused", "Restored transfer should be paused")
            try require(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("first.bin.aria2").path), "The partial transfer control file was lost")
            print("PASS: application-engine restart restores paused transfer and its control file")
            _ = try await URLSession.shared.data(from: URL(string: base + "/checkpoint")!)
            _ = try await engine.call("changeGlobalOption", [["max-overall-download-limit": "0", "max-concurrent-downloads": "1", "split": "4", "max-connection-per-server": "4"]])
            _ = try await engine.call("unpause", [first])
            let finished = try await waitFor(engine, first, timeout: 45) { $0["status"] as? String == "complete" }
            let payload = try Data(contentsOf: downloads.appendingPathComponent("first.bin"))
            let (expectedData, _) = try await URLSession.shared.data(from: URL(string: base + "/expected-sha256")!)
            let expected = String(decoding: expectedData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            try require(actual == expected, "Downloaded SHA-256 does not match fixture")
            try require(finished["completedLength"] as? String == String(payload.count), "Completed byte count is incorrect")
            print("PASS: resumed download completes with matching SHA-256 (\(payload.count) bytes)")
            _ = try await engine.call("forceRemove", [second])
            _ = try? await engine.call("removeDownloadResult", [second])
            let removed = try await engine.snapshot()
            try require(!removed.contains { $0["gid"] as? String == second }, "Removed item remains in queue")
            print("PASS: remove from queue")
            let missing = try await engine.add(source: base + "/missing", directory: downloads.path, filename: nil, preferences: settings)
            let deadline = Date().addingTimeInterval(15)
            var errorFound = false
            while Date() < deadline {
                let result = try await status(engine, missing)
                if result["status"] as? String == "error" { errorFound = true; break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try require(errorFound, "HTTP 404 did not become an error state")
            print("PASS: HTTP failure is surfaced")
            let (torrent, _) = try await URLSession.shared.data(from: URL(string: base + "/fixture.torrent")!)
            var pausedSettings = settings; pausedSettings.autoStart = false
            let torrentID = try await engine.add(source: "fixture.torrent", directory: downloads.path, filename: nil, preferences: pausedSettings, torrent: torrent.base64EncodedString())
            let torrentStatus = try await status(engine, torrentID)
            try require(torrentStatus["bittorrent"] != nil && torrentStatus["status"] as? String == "paused", "Torrent metadata was not accepted in paused state")
            print("PASS: torrent metadata import without contacting a swarm")
            await engine.shutdown()
            engine = TransferEngine(dataDirectory: directory.appendingPathComponent("engine"))
            try await engine.start(preferences: settings)
            let finalSnapshot = try await engine.snapshot()
            try require(!finalSnapshot.contains { $0["gid"] as? String == first }, "Completed download was incorrectly restored into the transfer queue")
            try require(finalSnapshot.contains { $0["gid"] as? String == torrentID }, "Paused torrent was not restored")
            print("PASS: restart retains unfinished jobs and does not requeue completed files")
            await engine.shutdown()
            _ = try await URLSession.shared.data(from: URL(string: base + "/checkpoint")!)
            try await ControlsSelfTest.run(base: base, directory: directory)
            print("ALL ENGINE INTEGRATION CHECKS PASSED")
            exit(0)
        } catch {
            await engine.shutdown()
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
