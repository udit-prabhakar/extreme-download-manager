import Foundation

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "All downloads", active = "Downloading", queued = "Queued", paused = "Paused", completed = "Completed", failed = "Failed"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .active: return "arrow.down.circle"
        case .queued: return "clock"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.status == "active"
        case .queued: return item.status == "waiting" || item.configuration.scheduledAt != nil
        case .paused: return item.status == "paused" && item.configuration.scheduledAt == nil
        case .completed: return item.status == "complete"
        case .failed: return item.status == "error"
        }
    }
}

struct DownloadItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var source: String
    var directory: String
    var status: String = "waiting"
    var total: Int64 = 0
    var completed: Int64 = 0
    var speed: Int64 = 0
    var uploadSpeed: Int64 = 0
    var connections: Int = 0
    var error: String = ""
    var files: [String] = []
    var added: Date = Date()
    var isTorrent: Bool = false
    var torrentData: String? = nil
    var followedBy: [String] = []
    // App identity stays stable when a retry or metadata transfer changes the engine ID.
    var engineID: String? = nil
    var uploadedBytes: Int64? = nil
    var uploadOffset: Int64? = nil
    var lastEngineUpload: Int64? = nil
    var fileDetails: [TransferFile]? = nil
    var bitfield: String? = nil
    var infoHash: String? = nil
    var trackerURLs: [String]? = nil
    var pieceCount: Int? = nil
    var isSeeding: Bool? = nil
    var configurationValue: DownloadConfiguration? = nil
    var verification: String? = nil
    var browserRequestID: UUID? = nil
    var gid: String { engineID ?? id }
    var configuration: DownloadConfiguration {
        get { configurationValue ?? DownloadConfiguration() }
        set { configurationValue = newValue }
    }
    var shareRatio: Double { completed > 0 ? Double(uploadedBytes ?? 0) / Double(completed) : 0 }
    var progress: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    var remaining: String {
        guard speed > 0, total > completed else { return "—" }
        let seconds = (total - completed) / speed
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    var statusLabel: String {
        if configuration.scheduledAt != nil { return "Scheduled" }
        switch status {
        case "active": return isTorrent && (isSeeding == true || (total > 0 && completed >= total)) ? "Seeding" : "Downloading"
        case "waiting": return "Queued"
        case "paused": return "Paused"
        case "complete": return "Completed"
        case "error": return "Failed"
        default: return status.capitalized
        }
    }
    var fileURL: URL { URL(fileURLWithPath: files.first ?? (directory as NSString).appendingPathComponent(name)) }
    static func fromRPC(_ object: [String: Any], previous: DownloadItem?) -> DownloadItem? {
        guard let gid = object["gid"] as? String else { return nil }
        let fileObjects = object["files"] as? [[String: Any]] ?? []
        let paths = fileObjects.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }
        let torrent = object["bittorrent"] as? [String: Any]
        let torrentName = (torrent?["info"] as? [String: Any])?["name"] as? String
        let uri = fileObjects.flatMap { $0["uris"] as? [[String: Any]] ?? [] }.compactMap { $0["uri"] as? String }.first
        var item = previous ?? DownloadItem(id: UUID().uuidString, name: "Resolving download…", source: uri ?? "", directory: object["dir"] as? String ?? "")
        item.engineID = gid
        item.status = object["status"] as? String ?? item.status
        item.name = torrentName ?? paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.name
        item.total = Int64(object["totalLength"] as? String ?? "0") ?? 0
        item.completed = Int64(object["completedLength"] as? String ?? "0") ?? 0
        // aria2 restores paused entries lazily; it has not read their control files yet.
        if item.status == "paused", item.total == 0, let previous {
            item.total = previous.total; item.completed = previous.completed
        }
        item.speed = Int64(object["downloadSpeed"] as? String ?? "0") ?? 0
        item.uploadSpeed = Int64(object["uploadSpeed"] as? String ?? "0") ?? 0
        item.connections = Int(object["connections"] as? String ?? "0") ?? 0
        item.error = object["errorMessage"] as? String ?? ""
        if object["files"] != nil {
            item.files = paths
            item.fileDetails = fileObjects.compactMap(TransferFile.fromRPC)
        }
        if let uploaded = Int64(object["uploadLength"] as? String ?? ""), !(item.status == "paused" && object["totalLength"] as? String == "0") {
            var offset = item.uploadOffset ?? 0
            if let last = item.lastEngineUpload, uploaded < last { offset += last }
            item.uploadOffset = offset; item.lastEngineUpload = uploaded
            item.uploadedBytes = offset + uploaded
        }
        item.bitfield = object["bitfield"] as? String ?? item.bitfield
        item.infoHash = object["infoHash"] as? String ?? item.infoHash
        item.pieceCount = Int(object["numPieces"] as? String ?? "") ?? item.pieceCount
        if let value = object["seeder"] as? String { item.isSeeding = value == "true" }
        if let lists = torrent?["announceList"] as? [[String]] { item.trackerURLs = lists.flatMap { $0 } }
        item.isTorrent = item.isTorrent || torrent != nil
        item.followedBy = object["followedBy"] as? [String] ?? []
        return item
    }
}

struct AppPreferences: Codable {
    var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
    var connections = 8
    var concurrentDownloads = 3
    var speedLimit = "0"
    var autoStart = true
    var advanced: AdvancedPreferences? = nil
    var extra: AdvancedPreferences {
        get { advanced ?? AdvancedPreferences() }
        set { advanced = newValue }
    }
}

enum SeedMode: String, Codable, CaseIterable, Identifiable {
    case stop, ratio, time, unlimited
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stop: return "Stop when complete"
        case .ratio: return "Until share ratio"
        case .time: return "For a set time"
        case .unlimited: return "Keep seeding"
        }
    }
}

struct AdvancedPreferences: Codable, Equatable {
    var uploadLimit = "0"
    var seedMode: SeedMode = .stop
    var seedRatio = 2.0
    var seedMinutes = 60
    var queueNames = ["Default", "Work", "Media"]
    var theme = "light"
}

struct ResourceIdentity: Codable, Equatable {
    var length: Int64?
    var etag: String?
    var modified: String?
    func matches(_ other: ResourceIdentity) -> Bool {
        guard let length, length > 0, length == other.length else { return false }
        if let etag, let otherTag = other.etag {
            guard etag == otherTag else { return false }
            if !etag.hasPrefix("W/"), !otherTag.hasPrefix("W/") { return true }
        }
        if let modified, let otherModified = other.modified { return modified == otherModified }
        return false
    }
}

struct DownloadConfiguration: Codable, Equatable {
    var downloadLimit = "0"
    var uploadLimit = "0"
    var connections = 8
    var seedMode: SeedMode = .stop
    var seedRatio = 2.0
    var seedMinutes = 60
    var sequential = false
    var selectedFiles: [Int]? = nil
    var queue = "Default"
    var scheduledAt: Date? = nil
    var sha256 = ""
    var identity: ResourceIdentity? = nil
    static func defaults(_ preferences: AppPreferences) -> DownloadConfiguration {
        var result = DownloadConfiguration()
        result.connections = preferences.connections
        result.seedMode = preferences.extra.seedMode
        result.seedRatio = preferences.extra.seedRatio
        result.seedMinutes = preferences.extra.seedMinutes
        return result
    }
    func validate() throws {
        for limit in [downloadLimit, uploadLimit] {
            guard limit.range(of: "^[0-9]+[KM]?$", options: .regularExpression) != nil else { throw EngineError(message: "Use a bandwidth value such as 256K, 5M, or 0 for unlimited.") }
        }
        guard (1...16).contains(connections), seedRatio.isFinite, (0.1...1000).contains(seedRatio), (1...525600).contains(seedMinutes) else { throw EngineError(message: "Check the connection count and seeding limits.") }
        guard sha256.isEmpty || sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw EngineError(message: "A SHA-256 checksum must contain exactly 64 hexadecimal characters.") }
        if let files = selectedFiles, files.isEmpty || files.contains(where: { $0 < 1 }) { throw EngineError(message: "Select at least one torrent file.") }
    }
    var engineOptions: [String: String] {
        var result = ["max-download-limit": downloadLimit, "max-upload-limit": uploadLimit,
                      "split": String(connections), "max-connection-per-server": String(connections), "check-integrity": "true"]
        switch seedMode {
        case .stop: result["seed-time"] = "0"; result["seed-ratio"] = "0"
        case .ratio: result["seed-ratio"] = String(seedRatio)
        case .time: result["seed-time"] = String(seedMinutes); result["seed-ratio"] = "0"
        case .unlimited: result["seed-ratio"] = "0"
        }
        if let selectedFiles { result["select-file"] = selectedFiles.sorted().map(String.init).joined(separator: ",") }
        result["stream-piece-selector"] = sequential ? "inorder" : "default"
        result["bt-prioritize-piece"] = sequential ? "head=8M,tail=2M" : ""
        if !sha256.isEmpty { result["checksum"] = "sha-256=" + sha256.lowercased() }
        if scheduledAt != nil { result["pause"] = "true" }
        return result
    }
}

struct TransferFile: Codable, Equatable, Identifiable {
    var id: Int
    var path: String
    var length: Int64
    var completed: Int64
    var selected: Bool
    static func fromRPC(_ value: [String: Any]) -> TransferFile? {
        guard let index = Int(value["index"] as? String ?? "") else { return nil }
        return TransferFile(id: index, path: value["path"] as? String ?? "", length: Int64(value["length"] as? String ?? "0") ?? 0,
                            completed: Int64(value["completedLength"] as? String ?? "0") ?? 0, selected: value["selected"] as? String != "false")
    }
}

func bytes(_ value: Int64) -> String {
    if value == 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
