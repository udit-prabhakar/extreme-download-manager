import Foundation
import AppKit

struct BrowserCapture: Codable, Identifiable, Equatable {
    let version: Int
    let id: UUID
    let url: String
    let title: String
    let browser: String
    let created: Date
}

enum BrowserBridge {
    static let hostName = "app.extreme.downloadmanager"
    static let chromiumID = "khfkcfjbpjhanmpplpkldiobnkkaoibj"
    static let firefoxID = "browser@extreme.downloadmanager.app"
    static let chromiumOrigin = "chrome-extension://" + chromiumID + "/"
    static let maximumMessage = 16 * 1024
    static var profileDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["EDM_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Extreme Download Manager", isDirectory: true)
    }
    static func inbox(_ profile: URL) -> URL { profile.appendingPathComponent("BrowserInbox", isDirectory: true) }

    static func validateURL(_ source: String) throws {
        guard !source.isEmpty, source.utf8.count <= 8192, !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }),
              let url = URL(string: source), let scheme = url.scheme?.lowercased(), ["http", "https", "magnet"].contains(scheme),
              url.user == nil, url.password == nil,
              scheme == "magnet" ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "xt" && $0.value?.hasPrefix("urn:btih:") == true }) == true : url.host?.isEmpty == false else {
            throw EngineError(message: "Send an HTTP, HTTPS, or BitTorrent magnet link without embedded credentials.")
        }
    }

    static func receive(_ message: Data, profile: URL, browser: String) throws -> [String: Any] {
        guard message.count <= maximumMessage, let object = try JSONSerialization.jsonObject(with: message) as? [String: Any],
              object["version"] as? Int == 1, let action = object["action"] as? String else { throw EngineError(message: "Unsupported browser message.") }
        if action == "ping" { return ["ok": true, "version": 1, "reviewRequired": true] }
        guard action == "handoff", let url = object["url"] as? String else { throw EngineError(message: "Unsupported browser action.") }
        try validateURL(url)
        let folder = inbox(profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count < 100 else { throw EngineError(message: "The browser inbox is full. Review or dismiss pending links in Extreme Download Manager.") }
        let cleanTitle = (object["title"] as? String ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let title = String(String.UnicodeScalarView(cleanTitle)).prefix(200)
        let capture = BrowserCapture(version: 1, id: UUID(), url: url, title: String(title), browser: browser, created: Date())
        let file = folder.appendingPathComponent(capture.id.uuidString + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(capture)
        guard data.count <= maximumMessage else { throw EngineError(message: "The browser link metadata is too large.") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ["ok": true, "version": 1, "queued": true, "requestID": capture.id.uuidString, "reviewRequired": true]
    }

    static func pending(profile: URL) throws -> [BrowserCapture] {
        let folder = inbox(profile)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        return files.filter { $0.pathExtension == "json" }.prefix(100).compactMap { file in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? .max) <= maximumMessage, let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(BrowserCapture.self, from: data),
                  item.version == 1, file.deletingPathExtension().lastPathComponent == item.id.uuidString,
                  item.created < Date().addingTimeInterval(300),
                  (try? validateURL(item.url)) != nil else { return nil }
            return item
        }.sorted { $0.created < $1.created }
    }

    static func acknowledge(_ id: UUID, profile: URL) throws {
        let file = inbox(profile).appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

enum BrowserNativeHost {
    private static func readExact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else { throw EngineError(message: "Incomplete browser message.") }
            data.append(chunk)
        }
        return data
    }
    private static func respond(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(data.count).littleEndian
        try FileHandle.standardOutput.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) } + data)
    }

    @MainActor static func run() async -> Int32 {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            let browser: String
            if arguments.first == BrowserBridge.chromiumOrigin || arguments.first == String(BrowserBridge.chromiumOrigin.dropLast()) { browser = "Chrome / Edge" }
            else if arguments.count == 2 && arguments[1] == BrowserBridge.firefoxID { browser = "Firefox" }
            else { throw EngineError(message: "This browser extension is not authorized.") }
            let header = try readExact(4)
            let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
            guard length > 0, length <= BrowserBridge.maximumMessage else { throw EngineError(message: "Browser message is too large or empty.") }
            var result = try BrowserBridge.receive(readExact(Int(length)), profile: BrowserBridge.profileDirectory, browser: browser)
            if result["queued"] as? Bool == true && ProcessInfo.processInfo.environment["EDM_NATIVE_HOST_NO_LAUNCH"] != "1" {
                let appURL = Bundle.main.bundleURL
                if appURL.pathExtension == "app" {
                    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                    // Keep explicit isolated development profiles isolated when waking the app.
                    let environment = ProcessInfo.processInfo.environment
                    configuration.environment = Dictionary(uniqueKeysWithValues: ["EDM_DATA_DIR", "EDM_OFFLINE_TEST", "EDM_BROWSER_LIBRARY"].compactMap { key in environment[key].map { (key, $0) } })
                    do { _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) }
                    catch { result["openAppManually"] = true }
                } else { result["openAppManually"] = true }
            }
            try respond(result)
            return 0
        } catch {
            try? respond(["ok": false, "error": error.localizedDescription])
            return 1
        }
    }
}
