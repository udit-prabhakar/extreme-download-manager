import Foundation
import Darwin

/// Owns one isolated aria2 process. RPC is loopback-only and uses a fresh secret.
@MainActor
final class TransferEngine {
    private var process: Process?
    private var endpoint: URL?
    private var secret = UUID().uuidString + UUID().uuidString
    let dataDirectory: URL
    private var logHandle: FileHandle?
    private var configURL: URL?
    private let session: URLSession
    private var lockDescriptor: Int32 = -1
    private var metadata: [String: [String: Any]] = [:]
    private var stoppedCache: [[String: Any]] = []
    private var lastStoppedRefresh = Date.distantPast
    var running: Bool { process?.isRunning == true }
    private(set) var peerPort = 0
    private(set) var executablePath = ""
    private(set) var version = ""
    private(set) var features: Set<String> = []
    var processID: Int32? { running ? process?.processIdentifier : nil }

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw EngineError(message: "Could not allocate a local engine port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw EngineError(message: "Could not bind a local engine port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { throw EngineError(message: "Could not read the local engine port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func start(preferences: AppPreferences) async throws {
        if running { return }
        try acquireProfile()
        do { try await startProcess(preferences: preferences) }
        catch { await shutdown(); throw error }
    }

    func acquireProfile() throws {
        guard lockDescriptor < 0 else { return }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockDescriptor = Darwin.open(dataDirectory.appendingPathComponent("engine.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            releaseLock()
            throw EngineError(message: "Another Extreme Download Manager instance is using this profile. Close it before opening this one.")
        }
    }

    func restart(preferences: AppPreferences) async throws {
        try acquireProfile()
        await stopProcess(releaseProfile: false)
        do { try await startProcess(preferences: preferences) }
        catch { await stopProcess(releaseProfile: false); throw error }
    }

    private func startProcess(preferences: AppPreferences) async throws {
        secret = UUID().uuidString + UUID().uuidString
        invalidate(); stoppedCache = []
        #if DEBUG
        let candidates = [ProcessInfo.processInfo.environment["EDM_ARIA2_PATH"], Bundle.main.url(forResource: "aria2c", withExtension: nil)?.path, "/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c"].compactMap { $0 }
        #else
        let candidates = [Bundle.main.url(forResource: "aria2c", withExtension: nil)?.path].compactMap { $0 }
        #endif
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EngineError(message: "The download engine is missing. Reinstall the complete app. Development builds can use aria2 installed through Homebrew.")
        }
        executablePath = executable
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sessionFile = dataDirectory.appendingPathComponent("transfers.session")
        if !FileManager.default.fileExists(atPath: sessionFile.path) { FileManager.default.createFile(atPath: sessionFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        let port = try availablePort()
        repeat { peerPort = try availablePort() } while peerPort == port
        endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
        let config = dataDirectory.appendingPathComponent("engine.conf")
        let text = """
        enable-rpc=true
        rpc-listen-all=false
        rpc-allow-origin-all=false
        rpc-listen-port=\(port)
        rpc-secret=\(secret)
        rpc-max-request-size=16M
        listen-port=\(peerPort)
        input-file=\(sessionFile.path)
        save-session=\(sessionFile.path)
        save-session-interval=5
        auto-save-interval=5
        force-save=false
        save-not-found=false
        stop-with-process=\(ProcessInfo.processInfo.processIdentifier)
        max-download-result=10000
        continue=true
        pause=true
        max-concurrent-downloads=\(preferences.concurrentDownloads)
        max-connection-per-server=\(preferences.connections)
        split=\(preferences.connections)
        min-split-size=1M
        max-overall-download-limit=\(preferences.speedLimit)
        max-overall-upload-limit=\(preferences.extra.uploadLimit)
        file-allocation=none
        auto-file-renaming=true
        allow-overwrite=false
        max-tries=5
        retry-wait=3
        connect-timeout=20
        timeout=60
        bt-save-metadata=true
        enable-dht=\(ProcessInfo.processInfo.environment["EDM_OFFLINE_TEST"] == "1" ? "false" : "true")
        enable-dht6=false
        enable-peer-exchange=\(ProcessInfo.processInfo.environment["EDM_OFFLINE_TEST"] == "1" ? "false" : "true")
        bt-enable-lpd=false
        dht-file-path=\(dataDirectory.appendingPathComponent("dht.dat").path)
        no-netrc=true
        check-certificate=true
        console-log-level=error
        summary-interval=0
        download-result=hide
        """
        try text.write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        configURL = config
        let log = dataDirectory.appendingPathComponent("engine.log")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: log.path), ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 1024 * 1024 {
            let previous = dataDirectory.appendingPathComponent("engine-previous.log")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try FileManager.default.moveItem(at: log, to: previous)
        }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
        logHandle = try FileHandle(forWritingTo: log)
        try logHandle?.seekToEnd()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--conf-path=\(config.path)"]
        child.currentDirectoryURL = dataDirectory
        child.standardOutput = logHandle
        child.standardError = logHandle
        // Do not inherit a user's unrelated aria2 configuration or proxy settings.
        child.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": dataDirectory.path, "LANG": "en_US.UTF-8"]
        try child.run()
        process = child
        for _ in 0..<40 {
            guard child.isRunning else {
                throw EngineError(message: "The download engine could not start. See \(log.path) for details.")
            }
            do {
                let info = try await call("getVersion") as? [String: Any] ?? [:]
                version = info["version"] as? String ?? "Unknown"
                features = Set(info["enabledFeatures"] as? [String] ?? [])
                return
            }
            catch { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        child.terminate()
        throw EngineError(message: "The download engine did not respond. Restart the app to try again.")
    }

    func call(_ method: String, _ parameters: [Any] = []) async throws -> Any {
        guard let endpoint else { throw EngineError(message: "The download engine is not ready.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "aria2." + method, "params": ["token:" + secret] + parameters])
        let (data, response) = try await session.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError(message: "Unexpected response from the local download engine.")
        }
        if let error = object["error"] as? [String: Any] {
            throw EngineError(message: error["message"] as? String ?? "Download operation failed.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EngineError(message: "The local engine returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
        if ["forceRemove", "remove", "removeDownloadResult", "unpause", "forcePause", "forcePauseAll", "unpauseAll", "changeOption"].contains(method) { invalidate() }
        return object["result"] ?? NSNull()
    }

    func snapshot() async throws -> [[String: Any]] {
        let keys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "uploadSpeed", "uploadLength", "seeder", "connections", "errorCode", "errorMessage", "followedBy"]
        let active = try await call("tellActive", [keys]) as? [[String: Any]] ?? []
        let waiting = try await call("tellWaiting", [0, 10000, keys]) as? [[String: Any]] ?? []
        if Date().timeIntervalSince(lastStoppedRefresh) > 2 || !active.isEmpty {
            stoppedCache = try await call("tellStopped", [0, 10000, keys]) as? [[String: Any]] ?? []
            lastStoppedRefresh = Date()
        }
        var records: [[String: Any]] = []
        for raw in active + waiting + stoppedCache {
            guard let gid = raw["gid"] as? String else { continue }
            if metadata[gid] == nil || metadata[gid]?["status"] as? String != raw["status"] as? String {
                metadata[gid] = try await call("tellStatus", [gid, keys + ["files", "dir", "bittorrent", "infoHash"]]) as? [String: Any]
            }
            records.append((metadata[gid] ?? [:]).merging(raw) { _, new in new })
        }
        return records
    }

    func add(source: String, directory: String, filename: String?, preferences: AppPreferences, torrent: String? = nil, configuration: DownloadConfiguration? = nil) async throws -> String {
        var options = ["dir": directory, "split": String(preferences.connections), "max-connection-per-server": String(preferences.connections), "pause": preferences.autoStart ? "false" : "true"]
        let configuration = configuration ?? .defaults(preferences)
        try configuration.validateSource(source)
        options.merge(configuration.engineOptions) { _, new in new }
        if let filename, !filename.isEmpty { options["out"] = filename }
        let result: Any
        if let torrent { result = try await call("addTorrent", [torrent, [], options]) }
        else { result = try await call("addUri", [[source], options]) }
        guard let gid = result as? String else { throw EngineError(message: "The engine did not return a download ID.") }
        _ = try? await call("saveSession")
        lastStoppedRefresh = .distantPast
        return gid
    }

    func invalidate() { lastStoppedRefresh = .distantPast; metadata.removeAll() }

    private func releaseLock() {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor); lockDescriptor = -1 }
    }

    func shutdown() async { await stopProcess(releaseProfile: true) }

    private func stopProcess(releaseProfile: Bool) async {
        if running {
            _ = try? await call("forcePauseAll")
            // Pause is asynchronous in aria2; wait for file/control-state finalization.
            for _ in 0..<60 {
                if let entries = try? await snapshot(), !entries.contains(where: { ["active", "waiting"].contains($0["status"] as? String ?? "") }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = try? await call("saveSession")
            _ = try? await call("shutdown")
            for _ in 0..<100 {
                if !running { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if running { process?.terminate() }
            for _ in 0..<100 {
                if !running { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if let process, process.isRunning {
                // Only this owned child, after graceful shutdown and SIGTERM deadlines.
                kill(process.processIdentifier, SIGKILL)
                for _ in 0..<40 {
                    if !process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        try? logHandle?.close()
        logHandle = nil
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
        configURL = nil; endpoint = nil; process = nil
        invalidate(); stoppedCache = []
        if releaseProfile { releaseLock() }
    }
}
