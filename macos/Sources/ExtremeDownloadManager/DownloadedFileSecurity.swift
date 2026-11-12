import Foundation
import CoreServices

enum DownloadedFileSecurity {
    /// Apply macOS download checks without copying private source URLs into file metadata.
    static func quarantine(paths: [String], directory: String) throws {
        let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var marked = 0
        for path in paths where FileManager.default.fileExists(atPath: path) {
            var file = URL(fileURLWithPath: path).standardizedFileURL
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .quarantinePropertiesKey])
            guard properties.isSymbolicLink != true, file.resolvingSymlinksInPath().path.hasPrefix(root) else { throw EngineError(message: "A downloaded path escapes its destination or is a symbolic link. Review it in Finder before opening.") }
            guard properties.isRegularFile == true else { continue }
            if properties.quarantineProperties != nil { marked += 1; continue }
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Extreme Download Manager", kLSQuarantineTimeStampKey as String: Date(), kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
            try file.setResourceValues(values)
            guard try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { throw EngineError(message: "This destination did not retain macOS quarantine metadata.") }
            marked += 1
        }
        guard marked > 0 else { throw EngineError(message: "The completed file is missing or is not a regular file. Review its destination in Finder.") }
    }
}
