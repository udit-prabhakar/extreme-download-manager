import SwiftUI
import AppKit

@MainActor
struct HealthView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestore = false
    @State private var freeSpace = "Checking…"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Engine & storage").font(.title2.bold())
            Label(store.engineMessage, systemImage: store.ready ? "checkmark.shield" : "exclamationmark.triangle").foregroundStyle(store.ready ? .teal : .orange)
            if !store.lastEngineError.isEmpty { Text(store.lastEngineError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { Text("Engine").foregroundStyle(.secondary); Text(store.engine.version.isEmpty ? "Unavailable" : "aria2 " + store.engine.version) }
                GridRow { Text("Source").foregroundStyle(.secondary); Text(store.engine.executablePath.contains(Bundle.main.bundlePath + "/") ? "Bundled with app" : "External development engine") }
                GridRow { Text("Features").foregroundStyle(.secondary); Text(store.engine.features.sorted().joined(separator: ", ")).font(.caption) }
                GridRow { Text("Free space").foregroundStyle(.secondary); Text(freeSpace) }
            }.font(.callout)
            Text("Recovery restarts only this app’s engine. Previously active downloads resume; paused downloads stay paused. After three unsuccessful attempts, use Retry connection.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(store.recoveringEngine ? "Recovering…" : "Retry connection") { Task { await store.recoverEngine(manual: true) } }.disabled(store.recoveringEngine)
                Button("Open app data") { NSWorkspace.shared.open(store.dataDirectory) }
            }
            Divider()
            Text("History recovery").font(.headline)
            Text("A consistent local backup is refreshed at most once per hour when history is saved. Restoring uses the last backup, so newer history records may be absent. Downloaded and partial files are kept.").font(.caption).foregroundStyle(.secondary)
            Button("Restore history backup…") { confirmRestore = true }
                .disabled(!store.canRestoreHistory)
            Text("Restore is available when startup cannot read history. The current database and its WAL files are preserved in a separate folder before replacement.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 590)
            .task {
                let directory = store.dataDirectory
                let available = await Task.detached { (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value }.value
                freeSpace = available.map(bytes) ?? "Unavailable"
            }
            .confirmationDialog("Restore the last history backup?", isPresented: $confirmRestore) {
                Button("Restore and preserve current history") { Task { await store.restoreHistoryBackup() } }
            } message: { Text("Newer history records may be missing from the backup. Current database files are preserved; downloads are not deleted.") }
            .transferErrorAlert(store)
    }
}
