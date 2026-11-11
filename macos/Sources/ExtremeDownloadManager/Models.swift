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
        case .queued: return item.status == "waiting"
        case .paused: return item.status == "paused"
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
    var progress: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    var remaining: String {
        guard speed > 0, total > completed else { return "—" }
        let seconds = (total - completed) / speed
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    var statusLabel: String {
        switch status {
        case "active": return total > 0 && completed >= total && isTorrent ? "Seeding" : "Downloading"
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
        var item = previous ?? DownloadItem(id: gid, name: "Resolving download…", source: uri ?? "", directory: object["dir"] as? String ?? "")
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
        item.files = paths
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
}

func bytes(_ value: Int64) -> String {
    if value == 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
