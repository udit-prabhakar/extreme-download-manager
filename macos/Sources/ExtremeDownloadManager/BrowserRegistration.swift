import Foundation

enum IntegratedBrowser: String, CaseIterable, Identifiable {
    case chrome = "Chrome", edge = "Edge", firefox = "Firefox"
    var id: String { rawValue }
    var folder: String {
        switch self {
        case .chrome: return "Application Support/Google/Chrome/NativeMessagingHosts"
        case .edge: return "Application Support/Microsoft Edge/NativeMessagingHosts"
        case .firefox: return "Application Support/Mozilla/NativeMessagingHosts"
        }
    }
    var extensionFolder: String { self == .firefox ? "firefox" : "chromium" }
}

enum BrowserRegistration {
    static var userLibrary: URL {
        if let override = ProcessInfo.processInfo.environment["EDM_BROWSER_LIBRARY"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    }
    static func manifest(_ browser: IntegratedBrowser, library: URL) -> URL {
        library.appendingPathComponent(browser.folder).appendingPathComponent(BrowserBridge.hostName + ".json")
    }
    static func helper(in app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/EDMBrowserHost") }
    static func install(_ browser: IntegratedBrowser, app: URL, library: URL = userLibrary) throws {
        let helper = helper(in: app)
        guard app.pathExtension == "app", FileManager.default.isExecutableFile(atPath: helper.path) else { throw EngineError(message: "Build or move the full Extreme Download Manager.app to a permanent location first.") }
        let file = manifest(browser, library: library)
        if FileManager.default.fileExists(atPath: file.path) { try verifyOwned(file) }
        var object: [String: Any] = ["name": BrowserBridge.hostName, "description": "Extreme Download Manager link handoff", "path": helper.path, "type": "stdio"]
        if browser == .firefox { object["allowed_extensions"] = [BrowserBridge.firefoxID] }
        else { object["allowed_origins"] = [BrowserBridge.chromiumOrigin] }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func remove(_ browser: IntegratedBrowser, library: URL = userLibrary) throws {
        let file = manifest(browser, library: library)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try verifyOwned(file)
        try FileManager.default.removeItem(at: file)
    }
    static func status(_ browser: IntegratedBrowser, app: URL, library: URL = userLibrary) -> String {
        let file = manifest(browser, library: library)
        guard FileManager.default.fileExists(atPath: file.path) else { return "Bridge not registered" }
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["path"] as? String == helper(in: app).path,
              FileManager.default.isExecutableFile(atPath: helper(in: app).path) else { return "Registration needs repair — register again from this app" }
        return "Bridge registered — load the extension in your browser"
    }
    private static func verifyOwned(_ file: URL) throws {
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["name"] as? String == BrowserBridge.hostName,
              (object["path"] as? String).map({ URL(fileURLWithPath: $0).lastPathComponent == "EDMBrowserHost" }) == true else {
            throw EngineError(message: "An unrecognized registration occupies this path. It was left unchanged: \(file.path)")
        }
    }
}
