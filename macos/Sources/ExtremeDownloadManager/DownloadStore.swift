import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    @Published var items: [DownloadItem] = []
    @Published var preferences = AppPreferences()
    @Published var filter: DownloadFilter = .all
    @Published var search = ""
    @Published var selection: String?
    @Published var ready = false
    @Published var engineMessage = "Starting download engine…"
    @Published var errorMessage: String?
    @Published var showingAdd = false
    @Published var showingSettings = false
    @Published var speedHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var totalSpeed: Int64 = 0
    @Published var uploadSpeed: Int64 = 0
    @Published var servers: [String] = []
    @Published var incomingURL = ""
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var stopping = false
    private var refreshing = false
    private var lastSave = Date.distantPast
    private var pendingTorrents: [URL] = []
    let dataDirectory: URL
    let engine: TransferEngine

    private init() {
        if let override = ProcessInfo.processInfo.environment["EDM_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Extreme Download Manager", isDirectory: true)
        }
        engine = TransferEngine(dataDirectory: dataDirectory)
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("preferences.json")),
           let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) { preferences = saved }
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("history.json")) {
            do {
                items = try JSONDecoder().decode([DownloadItem].self, from: data)
                for i in items.indices where ["active", "waiting"].contains(items[i].status) {
                    items[i].status = "paused"; items[i].speed = 0
                }
            } catch {
                try? data.write(to: dataDirectory.appendingPathComponent("history-recovery-\(Int(Date().timeIntervalSince1970)).json"))
                errorMessage = "Download history could not be read. A recovery copy was retained in the application data folder."
            }
        }
    }

    var visibleItems: [DownloadItem] {
        items.filter { item in
            filter.matches(item) && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.source.localizedCaseInsensitiveContains(search))
        }.sorted { $0.added > $1.added }
    }
    var selectedItem: DownloadItem? { items.first { $0.id == selection } }
    var activeCount: Int { items.filter { $0.status == "active" }.count }
    var finishedCount: Int { items.filter { $0.status == "complete" }.count }
    var downloadedBytes: Int64 { items.reduce(0) { $0 + $1.completed } }
    var peakSpeed: Int64 { Int64(speedHistory.max() ?? 0) }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await engine.start(preferences: preferences)
            // History owns completed entries. Never restore them into the transfer queue.
            for item in items where item.status == "complete" {
                if let state = try? await engine.call("tellStatus", [item.id]) as? [String: Any],
                   ["paused", "waiting", "active"].contains(state["status"] as? String ?? "") {
                    _ = try? await engine.call("forceRemove", [item.id])
                    _ = try? await engine.call("removeDownloadResult", [item.id])
                }
            }
            _ = try? await engine.call("saveSession")
            ready = true; engineMessage = "Engine connected"
            let launchTorrents = pendingTorrents
            pendingTorrents.removeAll()
            for url in launchTorrents { await addTorrent(url) }
            await refresh()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, let self else { break }
                    await self.refresh()
                }
            }
        } catch { engineMessage = "Engine unavailable"; errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard !refreshing, !stopping else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await engine.snapshot()
            guard !stopping else { return }
            var map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for raw in snapshot {
                guard let gid = raw["gid"] as? String,
                      let item = DownloadItem.fromRPC(raw, previous: map[gid]) else { continue }
                map[gid] = item
            }
            // Magnet metadata jobs become new content jobs with different IDs.
            for parent in Array(map.values) where !parent.followedBy.isEmpty {
                for childID in parent.followedBy {
                    if var child = map[childID] {
                        if child.source.isEmpty { child.source = parent.source }
                        child.torrentData = child.torrentData ?? parent.torrentData
                        child.added = parent.added
                        map[childID] = child
                        if selection == parent.id { selection = childID }
                    }
                }
            }
            let metadataIDs = Set(map.values.filter { !$0.followedBy.isEmpty }.map(\.id))
            items = map.values.filter { !metadataIDs.contains($0.id) }.sorted { $0.added > $1.added }
            totalSpeed = items.reduce(0) { $0 + ($1.status == "active" ? $1.speed : 0) }
            uploadSpeed = items.reduce(0) { $0 + ($1.status == "active" ? $1.uploadSpeed : 0) }
            speedHistory.append(Double(totalSpeed)); if speedHistory.count > 60 { speedHistory.removeFirst() }
            ready = true; engineMessage = "Engine connected"
            if Date().timeIntervalSince(lastSave) > 3 { persist(); lastSave = Date() }
        } catch {
            if !stopping { ready = false; engineMessage = "Connection interrupted" }
        }
    }

    func addURLs(_ text: String, directory: String, filename: String) async -> Bool {
        guard ready else { errorMessage = "The download engine is not connected."; return false }
        let sources = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !sources.isEmpty else { errorMessage = "Enter at least one download URL."; return false }
        let accepted = ["http", "https", "ftp", "sftp", "magnet"]
        for source in sources {
            guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), accepted.contains(scheme),
                  scheme == "magnet" || url.host?.isEmpty == false else {
                errorMessage = "Enter a valid HTTP, HTTPS, FTP, SFTP, or magnet URL.\n\n\(source)"; return false
            }
        }
        guard filename.isEmpty || (filename != "." && filename != ".." && !filename.contains("/") && !filename.contains("\\") && !filename.contains("\n")) else {
            errorMessage = "The file name must be a name, without folders or line breaks."; return false
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: directory) else { throw EngineError(message: "The destination folder is not writable.") }
            for source in sources {
                let name = sources.count == 1 ? filename : ""
                let gid = try await engine.add(source: source, directory: directory, filename: name, preferences: preferences)
                let urlName = URL(string: source)?.lastPathComponent.removingPercentEncoding ?? ""
                items.append(DownloadItem(id: gid, name: !name.isEmpty ? name : (urlName.isEmpty ? "Resolving download…" : urlName), source: source, directory: directory, status: preferences.autoStart ? "waiting" : "paused", isTorrent: source.hasPrefix("magnet:")))
                selection = gid
                persist()
            }
            filter = .all; search = ""
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func importTorrent(_ url: URL? = nil) {
        if let url {
            if !ready { pendingTorrents.append(url) }
            else { Task { await addTorrent(url) } }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import a torrent"; panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { for url in urls { await addTorrent(url) } }
        }
    }

    private func addTorrent(_ url: URL) async {
        guard ready else { errorMessage = "Wait for the download engine to connect."; return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 10 * 1024 * 1024 else { throw EngineError(message: "The torrent file is too large (maximum 10 MB).") }
            let encoded = data.base64EncodedString()
            let gid = try await engine.add(source: url.absoluteString, directory: preferences.directory, filename: nil, preferences: preferences, torrent: encoded)
            items.append(DownloadItem(id: gid, name: url.deletingPathExtension().lastPathComponent, source: url.absoluteString, directory: preferences.directory, isTorrent: true, torrentData: encoded))
            selection = gid; filter = .all; persist(); await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func perform(_ operation: String, item: DownloadItem) async {
        do {
            if operation == "resume", ["error", "removed"].contains(item.status) {
                try await retry(item)
            } else {
                let method = operation == "pause" ? "forcePause" : "unpause"
                do { _ = try await engine.call(method, [item.id]) }
                catch {
                    if operation == "resume" { try await retry(item) } else { throw error }
                }
            }
            _ = try? await engine.call("saveSession")
            await refresh(); persist()
        } catch { errorMessage = error.localizedDescription }
    }

    private func retry(_ item: DownloadItem) async throws {
        guard !item.source.isEmpty else { throw EngineError(message: "This download has no saved source. Add its URL again.") }
        var options = preferences; options.autoStart = true
        let gid = try await engine.add(source: item.source, directory: item.directory, filename: item.isTorrent ? nil : item.name, preferences: options, torrent: item.torrentData)
        _ = try? await engine.call("removeDownloadResult", [item.id])
        items.removeAll { $0.id == item.id }
        var replacement = item; replacement.id = gid; replacement.status = "waiting"; replacement.error = ""
        items.append(replacement); selection = gid
    }

    func remove(_ item: DownloadItem) async {
        do {
            if ["active", "waiting", "paused"].contains(item.status) { _ = try await engine.call("forceRemove", [item.id]) }
            _ = try? await engine.call("removeDownloadResult", [item.id])
            items.removeAll { $0.id == item.id }
            if selection == item.id { selection = nil }
            _ = try? await engine.call("saveSession")
            persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func pauseAll() async {
        do { _ = try await engine.call("forcePauseAll"); _ = try await engine.call("saveSession"); await refresh(); persist() }
        catch { errorMessage = error.localizedDescription }
    }
    func resumeAll() async {
        do { _ = try await engine.call("unpauseAll"); await refresh(); persist() }
        catch { errorMessage = error.localizedDescription }
    }
    func reveal(_ item: DownloadItem) { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
    func open(_ item: DownloadItem) {
        if item.status == "complete" { NSWorkspace.shared.open(item.fileURL) } else { reveal(item) }
    }
    func chooseFolder(current: String) -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Choose folder"
        panel.directoryURL = URL(fileURLWithPath: current)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    func applyPreferences(_ newValue: AppPreferences) async -> Bool {
        do {
            _ = try await engine.call("changeGlobalOption", [["max-concurrent-downloads": String(newValue.concurrentDownloads), "max-overall-download-limit": newValue.speedLimit, "split": String(newValue.connections), "max-connection-per-server": String(newValue.connections)]])
            preferences = newValue; persist(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func inspectConnections() async {
        servers = []
        guard let item = selectedItem, item.status == "active" else { return }
        do {
            if item.isTorrent {
                let peers = try await engine.call("getPeers", [item.id]) as? [[String: Any]] ?? []
                servers = peers.map { "\($0["ip"] as? String ?? "Peer"):\($0["port"] as? String ?? "")" }
            } else {
                let groups = try await engine.call("getServers", [item.id]) as? [[String: Any]] ?? []
                servers = groups.flatMap { $0["servers"] as? [[String: Any]] ?? [] }.map {
                    let uri = $0["currentUri"] as? String ?? $0["uri"] as? String ?? ""
                    return "\(URL(string: uri)?.host ?? "Server")  ·  \(bytes(Int64($0["downloadSpeed"] as? String ?? "0") ?? 0))/s"
                }
            }
        } catch { servers = [] }
    }
    func persist() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for (name, data) in [("history.json", try encoder.encode(items)), ("preferences.json", try encoder.encode(preferences))] {
                let url = dataDirectory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch { errorMessage = "Could not save download history: \(error.localizedDescription)" }
    }
    func shutdown() async {
        stopping = true; pollTask?.cancel()
        await engine.shutdown()
        for i in items.indices where ["active", "waiting"].contains(items[i].status) { items[i].status = "paused"; items[i].speed = 0 }
        persist()
    }
}
