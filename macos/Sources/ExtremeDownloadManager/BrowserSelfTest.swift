import Foundation

@MainActor
enum BrowserSelfTest {
    static func run(base: String, store: DownloadStore, directory: URL) async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw EngineError(message: message) } }
        // Registration tests write only inside the generated test directory.
        let app = directory.appendingPathComponent("Browser fixture.app")
        let helper = BrowserRegistration.helper(in: app)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let library = directory.appendingPathComponent("browser-test-library")
        for browser in IntegratedBrowser.allCases {
            try BrowserRegistration.install(browser, app: app, library: library)
            let manifest = BrowserRegistration.manifest(browser, library: library)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] ?? [:]
            try check(object["path"] as? String == helper.path, "Browser host path was not registered")
            if browser == .firefox { try check(object["allowed_extensions"] as? [String] == [BrowserBridge.firefoxID], "Firefox allowlist mismatch") }
            else { try check(object["allowed_origins"] as? [String] == [BrowserBridge.chromiumOrigin], "Chromium allowlist mismatch") }
            let unrelated = manifest.deletingLastPathComponent().appendingPathComponent("other.host.json")
            try Data("unrelated".utf8).write(to: unrelated)
            try BrowserRegistration.remove(browser, library: library)
            try check(!FileManager.default.fileExists(atPath: manifest.path) && FileManager.default.fileExists(atPath: unrelated.path), "Unregister touched another host")
        }
        print("PASS: Chrome, Edge, and Firefox registrations contain narrow allowlists and uninstall preserves other hosts")

        let before = store.items.count
        let packet = try JSONSerialization.data(withJSONObject: ["version": 1, "action": "handoff", "url": base + "/payload.bin", "title": "Browser fixture"])
        _ = try BrowserBridge.receive(packet, profile: store.dataDirectory, browser: "Test browser")
        await store.refreshBrowserInbox()
        try check(store.browserCaptures.count == 1 && store.items.count == before, "Browser handoff started a transfer before review")
        let capture = store.browserCaptures[0]
        store.preferences.autoStart = false
        let accepted = await store.acceptBrowserCapture(capture, directory: store.preferences.directory, filename: "browser-reviewed.bin")
        try check(accepted && store.browserCaptures.isEmpty, "Reviewed browser link was not acknowledged")
        guard let item = store.items.first(where: { $0.browserRequestID == capture.id }) else { throw EngineError(message: "Browser request identity was not saved") }
        try check(item.status == "paused" && item.completed == 0, "Browser handoff ignored the automatic-start preference")
        _ = try BrowserBridge.receive(packet, profile: store.dataDirectory, browser: "Test browser")
        await store.refreshBrowserInbox()
        guard let second = store.browserCaptures.first else { throw EngineError(message: "Second browser link was not queued") }
        let reused = await store.acceptBrowserCapture(second, directory: store.preferences.directory, filename: "unused.bin")
        try check(reused && store.items.count == before + 1 && store.items.first(where: { $0.id == item.id })?.browserRequestIDs?.contains(capture.id) == true, "Reusing a transfer lost its earlier request identity")
        // Simulate an acknowledgement interrupted by process exit; accepting again must not add a second job.
        let file = BrowserBridge.inbox(store.dataDirectory).appendingPathComponent(capture.id.uuidString + ".json")
        try JSONEncoder().encode(capture).write(to: file)
        await store.refreshBrowserInbox()
        let count = store.items.count
        let retried = await store.acceptBrowserCapture(capture, directory: store.preferences.directory, filename: "unused.bin")
        try check(retried && store.items.count == count, "Repeated browser request created a duplicate job")
        await store.perform("resume", item: item)
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            await store.refresh()
            if store.items.first(where: { $0.id == item.id })?.status == "complete" { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try check(store.items.first(where: { $0.id == item.id })?.status == "complete", "Reviewed browser transfer did not complete")
        let expected = try await URLSession.shared.data(from: URL(string: base + "/expected-sha256")!).0
        let actual = try TransferUtilities.sha256(URL(fileURLWithPath: store.preferences.directory).appendingPathComponent("browser-reviewed.bin"))
        try check(actual == String(decoding: expected, as: UTF8.self), "Browser transfer checksum mismatch")
        try JSONEncoder().encode(capture).write(to: file)
        await store.refreshBrowserInbox()
        let completedReplay = await store.acceptBrowserCapture(capture, directory: store.preferences.directory, filename: "unused-completed.bin")
        try check(completedReplay && store.items.count == count, "An earlier browser request replayed after completion created another job")
        _ = try BrowserBridge.receive(packet, profile: store.dataDirectory, browser: "Test browser")
        await store.refreshBrowserInbox()
        if let pending = store.browserCaptures.first { await store.dismissBrowserCapture(pending) }
        try check(store.browserCaptures.isEmpty && store.items.count == count, "Dismissing a browser link added a job")
        store.preferences.autoStart = true
        print("PASS: browser links require review, respect paused defaults, deduplicate retries, dismiss without transfer, and download correct bytes")
    }
}
