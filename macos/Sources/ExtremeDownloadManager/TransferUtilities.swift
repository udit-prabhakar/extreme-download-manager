import Foundation
import CryptoKit

enum TransferUtilities {
    static func identity(for source: String) async -> ResourceIdentity? {
        guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return ResourceIdentity(length: Int64(http.value(forHTTPHeaderField: "Content-Length") ?? ""), etag: http.value(forHTTPHeaderField: "ETag"), modified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func guidance(for error: String) -> String {
        let text = error.lowercased()
        if text.contains("403") || text.contains("401") { return "The server rejected access. The link may have expired or require authentication; use Repair link with a fresh URL." }
        if text.contains("404") || text.contains("not found") { return "The file was not found. Check the source URL or use Repair link." }
        if text.contains("429") { return "The server is rate limiting this transfer. Pause it, wait, and reduce connections before retrying." }
        if text.contains("space") || text.contains("disk") { return "Check free space and whether the destination drive is connected and writable." }
        if text.contains("certificate") || text.contains("ssl") { return "The secure connection failed certificate validation. Check the system clock and the source server." }
        if text.contains("checksum") || text.contains("hash") { return "Downloaded data failed integrity verification. Recheck the source and expected checksum." }
        return "Check the connection and destination. Retry after correcting the cause; partial files are retained for resume."
    }
}
