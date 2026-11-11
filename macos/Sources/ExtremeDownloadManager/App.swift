import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task {
            await DownloadStore.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL && url.pathExtension.lowercased() == "torrent" { DownloadStore.shared.importTorrent(url) }
            else { DownloadStore.shared.incomingURL = url.absoluteString; DownloadStore.shared.showingAdd = true }
        }
    }
}

@MainActor
struct ExtremeDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DownloadStore.shared
    var body: some Scene {
        WindowGroup("Extreme Download Manager") {
            MainView(store: store)
        }.defaultSize(width: 1180, height: 780)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New download…") { store.showingAdd = true }.keyboardShortcut("n").disabled(!store.ready)
                    Button("Import torrent…") { store.importTorrent() }.keyboardShortcut("o").disabled(!store.ready)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Preferences…") { store.showingSettings = true }.keyboardShortcut(",")
                }
                CommandMenu("Downloads") {
                    Button("Pause all") { Task { await store.pauseAll() } }.disabled(!store.ready)
                    Button("Resume all") { Task { await store.resumeAll() } }.disabled(!store.ready)
                    Divider()
                    Button("Open download folder") { NSWorkspace.shared.open(URL(fileURLWithPath: store.preferences.directory)) }
                }
            }
    }
}
