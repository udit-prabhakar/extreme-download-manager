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
    @Published var editingTransfer: DownloadItem?
    @Published var inspectorTab = 0
    @Published var selectedIDs: Set<String> = []
    @Published var queueFilter = ""
    @Published var verifyingIDs: Set<String> = []
    private var newTorrentIDs: Set<String> = []
    private var database: HistoryDatabase?
    private var persistenceTask: Task<Void, Never>?
    private var schedulerRunning = false
    private var lastSave = Date.distantPast
    private var pendingTorrents: [URL] = []
    let dataDirectory: URL
    let engine: TransferEngine

    init(directory: URL? = nil) {
        if let directory {
            dataDirectory = directory
        } else if let override = ProcessInfo.processInfo.environment["EDM_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Extreme Download Manager", isDirectory: true)
        }
        engine = TransferEngine(dataDirectory: dataDirectory)
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("preferences.json")),
           let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) { preferences = saved }
    }


    var visibleItems: [DownloadItem] {
        items.filter { item in
            (queueFilter.isEmpty || item.configuration.queue == queueFilter) && filter.matches(item) && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.source.localizedCaseInsensitiveContains(search))
        }.sorted { $0.added > $1.added }
    }
    var actionTargets: [DownloadItem] { items.filter { selectedIDs.contains($0.id) || (selectedIDs.isEmpty && $0.id == selection) } }
    var selectedItem: DownloadItem? { items.first { $0.id == selection } }
    var activeCount: Int { items.filter { $0.status == "active" }.count }
    var finishedCount: Int { items.filter { $0.status == "complete" }.count }
    var downloadedBytes: Int64 { items.reduce(0) { $0 + $1.completed } }
    var peakSpeed: Int64 { Int64(speedHistory.max() ?? 0) }

    func start() async {
        guard !started else { return }
        started = true
        do {
            // Acquire profile ownership before reading or migrating shared history.
            try await engine.start(preferences: preferences)
            let directory = dataDirectory
            let database = try await Task.detached { try HistoryDatabase(directory: directory) }.value
            self.database = database
            items = try await database.load()
            for index in items.indices where ["active", "waiting"].contains(items[index].status) {
                items[index].status = "paused"; items[index].speed = 0
            }
            // History owns completed entries. Never restore them into the transfer queue.
            for item in items where item.status == "complete" {
                if let state = try? await engine.call("tellStatus", [item.gid]) as? [String: Any],
                   ["paused", "waiting", "active"].contains(state["status"] as? String ?? "") {
                    _ = try? await engine.call("forceRemove", [item.gid])
                    _ = try? await engine.call("removeDownloadResult", [item.gid])
                }
            }
            _ = try? await engine.call("saveSession")
            ready = true; engineMessage = "Engine connected"
            let launchTorrents = pendingTorrents
            pendingTorrents.removeAll()
            for url in launchTorrents { await addTorrent(url) }
            await refresh()
            await runScheduled()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, let self else { break }
                    await self.refresh()
                    await self.runScheduled()
                }
            }
        } catch { await engine.shutdown(); database = nil; started = false; engineMessage = "Engine unavailable"; errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard !refreshing, !stopping else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await engine.snapshot()
            guard !stopping else { return }
            var map = Dictionary(uniqueKeysWithValues: items.map { ($0.gid, $0) })
            for raw in snapshot {
                guard let gid = raw["gid"] as? String,
                      let item = DownloadItem.fromRPC(raw, previous: map[gid]) else { continue }
                map[gid] = item
            }
            // Magnet metadata jobs become new content jobs with different IDs.
            for parent in Array(map.values) where !parent.followedBy.isEmpty {
                for (position, childID) in parent.followedBy.enumerated() {
                    if var child = map[childID] {
                        if child.source.isEmpty { child.source = parent.source }
                        child.torrentData = child.torrentData ?? parent.torrentData
                        child.added = parent.added
                        if position == 0 { child.id = parent.id }
                        child.configurationValue = parent.configurationValue
                        map[childID] = child
                        if selectedIDs.contains(parent.id) { selectedIDs.insert(child.id) }
                        if selection == parent.id { selection = child.id }
                    }
                }
            }
            let metadataIDs = Set(map.values.filter { !$0.followedBy.isEmpty }.map(\.gid))
            items = map.values.filter { !metadataIDs.contains($0.gid) }.sorted { $0.added > $1.added }
            totalSpeed = items.reduce(0) { $0 + ($1.status == "active" ? $1.speed : 0) }
            uploadSpeed = items.reduce(0) { $0 + ($1.status == "active" ? $1.uploadSpeed : 0) }
            speedHistory.append(Double(totalSpeed)); if speedHistory.count > 60 { speedHistory.removeFirst() }
            ready = true; engineMessage = "Engine connected"
            if Date().timeIntervalSince(lastSave) > 3 { persist(); lastSave = Date() }
        } catch {
            if !stopping { ready = false; engineMessage = "Connection interrupted" }
        }
    }

    func addURLs(_ text: String, directory: String, filename: String, configuration: DownloadConfiguration? = nil) async -> Bool {
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
            var baseConfiguration = configuration ?? .defaults(preferences)
            baseConfiguration.queue = baseConfiguration.queue.trimmingCharacters(in: .whitespacesAndNewlines)
            if baseConfiguration.queue.isEmpty { baseConfiguration.queue = "Default" }
            try baseConfiguration.validate()
            if !preferences.extra.queueNames.contains(baseConfiguration.queue) { preferences.extra.queueNames.append(baseConfiguration.queue) }
            for source in sources {
                if let duplicate = items.first(where: { $0.source == source && $0.directory == directory && !["complete", "error", "removed"].contains($0.status) }) {
                    selection = duplicate.id; continue
                }
                baseConfiguration.identity = await TransferUtilities.identity(for: source)
                try Task.checkCancellation()
                let name = sources.count == 1 ? filename : ""
                let gid = try await engine.add(source: source, directory: directory, filename: name, preferences: preferences, configuration: baseConfiguration)
                let urlName = URL(string: source)?.lastPathComponent.removingPercentEncoding ?? ""
                var item = DownloadItem(id: UUID().uuidString, name: !name.isEmpty ? name : (urlName.isEmpty ? "Resolving download…" : urlName), source: source, directory: directory, status: preferences.autoStart ? "waiting" : "paused", isTorrent: source.hasPrefix("magnet:"))
                item.engineID = gid; item.configuration = baseConfiguration
                items.append(item)
                selection = item.id; selectedIDs = [item.id]
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
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            guard data.count < 10 * 1024 * 1024 else { throw EngineError(message: "The torrent file is too large (maximum 10 MB).") }
            let encoded = data.base64EncodedString()
            var paused = preferences; paused.autoStart = false
            let configuration = DownloadConfiguration.defaults(preferences)
            let gid = try await engine.add(source: url.absoluteString, directory: preferences.directory, filename: nil, preferences: paused, torrent: encoded, configuration: configuration)
            var item = DownloadItem(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, source: url.absoluteString, directory: preferences.directory, status: "paused", isTorrent: true, torrentData: encoded)
            item.engineID = gid; item.configuration = configuration
            items.append(item)
            selection = item.id; selectedIDs = [item.id]; filter = .all; queueFilter = ""
            newTorrentIDs.insert(item.id)
            persist(); await refresh()
            editingTransfer = items.first { $0.id == item.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func perform(_ operation: String, item: DownloadItem) async {
        do {
            var target = item
            if operation == "resume", let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].configuration.scheduledAt = nil
                target = items[index]
            }
            if operation == "resume" && (["error", "removed"].contains(item.status) || item.configurationValue == nil) {
                try await retry(target)
            } else {
                let method = operation == "pause" ? "forcePause" : "unpause"
                do { _ = try await engine.call(method, [item.gid]) }
                catch {
                    if operation == "resume" { try await retry(target) } else { throw error }
                }
            }
            _ = try? await engine.call("saveSession")
            await refresh(); persist()
        } catch { errorMessage = error.localizedDescription }
    }

    private func retry(_ item: DownloadItem, replacementSource: String? = nil, configuration: DownloadConfiguration? = nil, freshFile: Bool = false, autoStart: Bool = true) async throws {
        let source = replacementSource ?? item.source
        guard !source.isEmpty else { throw EngineError(message: "This download has no saved source. Add its URL again.") }
        let config = configuration ?? item.configuration
        try config.validate()
        if let state = try? await engine.call("tellStatus", [item.gid]) as? [String: Any], ["active", "waiting", "paused"].contains(state["status"] as? String ?? "") {
            if state["status"] as? String != "paused" {
                _ = try await engine.call("forcePause", [item.gid])
                try await waitForPause(item.gid)
            }
            _ = try await engine.call("forceRemove", [item.gid])
        }
        _ = try? await engine.call("removeDownloadResult", [item.gid])
        var options = preferences; options.autoStart = autoStart
        var name = item.name
        if freshFile {
            let file = URL(fileURLWithPath: name)
            name = file.deletingPathExtension().lastPathComponent + " (restarted " + UUID().uuidString.prefix(8) + ")" + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
        }
        do {
            let gid = try await engine.add(source: source, directory: item.directory, filename: item.isTorrent ? nil : name, preferences: options, torrent: item.torrentData, configuration: config)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].engineID = gid; items[index].status = autoStart ? "waiting" : "paused"
                items[index].uploadOffset = items[index].uploadedBytes ?? 0; items[index].lastEngineUpload = 0
                items[index].source = source; items[index].name = name; items[index].error = ""
                items[index].configuration = config
                if freshFile { items[index].completed = 0; items[index].total = 0; items[index].files = []; items[index].fileDetails = nil }
            }
        } catch {
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].status = "error"; items[index].error = error.localizedDescription }
            persist(); throw error
        }
        selection = item.id; engine.invalidate(); persist()
    }

    private func waitForPause(_ gid: String) async throws {
        for _ in 0..<80 {
            let raw = try await engine.call("tellStatus", [gid]) as? [String: Any] ?? [:]
            if !["active", "waiting"].contains(raw["status"] as? String ?? "") { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw EngineError(message: "The transfer is still stopping. Wait before changing it.")
    }

    func remove(_ item: DownloadItem) async {
        do {
            if ["active", "waiting", "paused"].contains(item.status) { _ = try await engine.call("forceRemove", [item.gid]) }
            _ = try? await engine.call("removeDownloadResult", [item.gid])
            items.removeAll { $0.id == item.id }; selectedIDs.remove(item.id)
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
        for item in items where item.status == "paused" && item.configuration.scheduledAt == nil { await perform("resume", item: item) }
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
            var validation = DownloadConfiguration.defaults(newValue)
            validation.uploadLimit = newValue.extra.uploadLimit; validation.downloadLimit = newValue.speedLimit
            try validation.validate()
            _ = try await engine.call("changeGlobalOption", [["max-concurrent-downloads": String(newValue.concurrentDownloads), "max-overall-download-limit": newValue.speedLimit, "max-overall-upload-limit": newValue.extra.uploadLimit, "split": String(newValue.connections), "max-connection-per-server": String(newValue.connections)]])
            preferences = newValue; persist(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func inspectConnections() async {
        servers = []
        guard let item = selectedItem, item.status == "active" else { return }
        do {
            if item.isTorrent {
                let peers = try await engine.call("getPeers", [item.gid]) as? [[String: Any]] ?? []
                servers = peers.map { "\($0["ip"] as? String ?? "Peer"):\($0["port"] as? String ?? "")" }
            } else {
                let groups = try await engine.call("getServers", [item.gid]) as? [[String: Any]] ?? []
                servers = groups.flatMap { $0["servers"] as? [[String: Any]] ?? [] }.map {
                    let uri = $0["currentUri"] as? String ?? $0["uri"] as? String ?? ""
                    return "\(URL(string: uri)?.host ?? "Server")  ·  \(bytes(Int64($0["downloadSpeed"] as? String ?? "0") ?? 0))/s"
                }
            }
        } catch { servers = [] }
    }
    func persist() {
        guard let database else { return }
        let items = items, preferences = preferences, previous = persistenceTask
        persistenceTask = Task { [weak self] in
            await previous?.value
            do { try await database.save(items, preferences: preferences) }
            catch { self?.errorMessage = "Could not save download history: \(error.localizedDescription)" }
        }
    }

    func flushPersistence() async { await persistenceTask?.value }

    func shutdown() async {
        stopping = true; pollTask?.cancel()
        await engine.shutdown()
        for i in items.indices where ["active", "waiting"].contains(items[i].status) { items[i].status = "paused"; items[i].speed = 0 }
        persist(); await flushPersistence()
    }
}

extension DownloadStore {
    func select(_ id: String, extending: Bool = false) {
        if extending {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            selection = selectedIDs.contains(id) ? id : selectedIDs.first
        } else { selection = id; selectedIDs = [id] }
    }

    func selectAllVisible() { selectedIDs = Set(visibleItems.map(\.id)); selection = visibleItems.first?.id }

    func bulk(_ operation: String) async {
        let targets = actionTargets.isEmpty ? items : actionTargets
        for item in targets {
            if operation == "remove" { await remove(item) }
            else if operation == "pause", ["active", "waiting"].contains(item.status) { await perform(operation, item: item) }
            else if operation == "resume", ["paused", "error"].contains(item.status) { await perform(operation, item: item) }
        }
    }

    func prioritize(_ item: DownloadItem) async {
        do { _ = try await engine.call("changePosition", [item.gid, 0, "POS_SET"]); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func inspect(_ id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        do {
            let raw = try await engine.call("tellStatus", [items[index].gid]) as? [String: Any] ?? [:]
            if let updated = DownloadItem.fromRPC(raw, previous: items[index]) { items[index] = updated }
            selection = id
            await inspectConnections()
        } catch { /* Archived completed records remain inspectable without an engine job. */ }
    }

    func showControls(_ item: DownloadItem, tab: Int = 0) {
        inspectorTab = tab
        editingTransfer = item
        Task { await inspect(item.id) }
    }

    func isPreparedTorrent(_ id: String) -> Bool { newTorrentIDs.contains(id) }

    func saveControls(_ configuration: DownloadConfiguration, id: String, start: Bool = false) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            try configuration.validate()
            if let selected = configuration.selectedFiles {
                let available = Set((item.fileDetails ?? []).map(\.id))
                guard selected.allSatisfy(available.contains) else { throw EngineError(message: "The torrent file selection is no longer valid. Refresh its file list.") }
            }
            let restartCompletedTorrent = item.status == "complete" && item.isTorrent && (configuration.selectedFiles != item.configuration.selectedFiles || configuration.seedMode != item.configuration.seedMode || configuration.scheduledAt != nil)
            let shouldRun = (start || item.status == "active" || item.status == "waiting" || restartCompletedTorrent) && configuration.scheduledAt == nil
            if item.status == "complete" && !item.isTorrent && configuration.scheduledAt != nil { throw EngineError(message: "This file is already complete. Add a new download to schedule another transfer.") }
            if item.status == "complete" && !restartCompletedTorrent {
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].configuration = configuration }
            } else if restartCompletedTorrent || ["error", "removed"].contains(item.status) || configuration.seedMode != item.configuration.seedMode || configuration.sha256 != item.configuration.sha256 {
                try await retry(item, configuration: configuration, autoStart: shouldRun)
            } else {
                if ["active", "waiting"].contains(item.status) { _ = try await engine.call("forcePause", [item.gid]); try await waitForPause(item.gid) }
                var options = configuration.engineOptions; options.removeValue(forKey: "pause")
                _ = try await engine.call("changeOption", [item.gid, options])
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].configuration = configuration }
                if shouldRun { _ = try await engine.call("unpause", [item.gid]) }
            }
            if !preferences.extra.queueNames.contains(configuration.queue) && !configuration.queue.isEmpty { preferences.extra.queueNames.append(configuration.queue) }
            newTorrentIDs.remove(id)
            _ = try? await engine.call("saveSession")
            await refresh(); persist()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func repair(_ id: String, source: String, keepProgress: Bool) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), !item.isTorrent else { return false }
        guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { errorMessage = "Enter a valid HTTP or HTTPS replacement URL."; return false }
        let newIdentity = await TransferUtilities.identity(for: source)
        if keepProgress {
            guard let original = item.configuration.identity, let replacement = newIdentity, original.matches(replacement) else {
                errorMessage = "The server did not provide matching size and resource validators. To avoid mixing different files, choose ‘Start a separate file’. Your existing partial file will be kept."
                return false
            }
        }
        do {
            var configuration = item.configuration
            configuration.identity = newIdentity; configuration.scheduledAt = nil
            try await retry(item, replacementSource: source, configuration: configuration, freshFile: !keepProgress)
            await refresh(); persist(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func verifyChecksum(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }), item.status == "complete", !verifyingIDs.contains(id) else { return }
        verifyingIDs.insert(id)
        defer { verifyingIDs.remove(id) }
        do {
            let url = item.fileURL
            let hash = try await Task.detached { try TransferUtilities.sha256(url) }.value
            if let index = items.firstIndex(where: { $0.id == id }) {
                let expected = items[index].configuration.sha256.lowercased()
                items[index].verification = expected.isEmpty ? "SHA-256: " + hash : expected == hash ? "SHA-256 verified: " + hash : "CHECKSUM MISMATCH: " + hash
            }
            persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func runScheduled(now: Date = Date()) async {
        guard ready, !stopping, !schedulerRunning else { return }
        schedulerRunning = true
        defer { schedulerRunning = false }
        let due = items.filter { item in item.status == "paused" && item.configuration.scheduledAt.map { $0 <= now } == true }
        for item in due { await perform("resume", item: item) }
    }
}
