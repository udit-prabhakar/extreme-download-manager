// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ExtremeDownloadManager",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ExtremeDownloadManager", targets: ["ExtremeDownloadManager"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "ExtremeDownloadManager", dependencies: ["CSQLite"])
    ]
)
