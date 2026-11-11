import SwiftUI

@MainActor
struct TransferControlsView: View {
    @ObservedObject var store: DownloadStore
    let initial: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DownloadConfiguration()
    @State private var selectedFiles: Set<Int> = []
    @State private var saving = false
    @State private var tab = 0
    @State private var scheduleEnabled = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    @State private var replacementURL = ""
    @State private var keepProgress = true
    var item: DownloadItem { store.items.first { $0.id == initial.id } ?? initial }
    var prepared: Bool { store.isPreparedTorrent(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: item.isTorrent ? "point.3.connected.trianglepath.dotted" : "slider.horizontal.3").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prepared ? "Choose what to download" : "Download controls").font(.title2.weight(.semibold))
                    Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(item.statusLabel).font(.caption).foregroundStyle(.teal)
            }
            Picker("Inspector", selection: $tab) {
                Text("Controls").tag(0)
                if item.isTorrent { Text("Files").tag(1); Text("Peers & pieces").tag(2) }
                else { Text("Repair link").tag(3) }
                Text("Integrity").tag(4)
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 1: filesPanel
                    case 2: peersPanel
                    case 3: repairPanel
                    case 4: integrityPanel
                    default: controlsPanel
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 390)
            Divider()
            HStack {
                Button("Refresh details") { Task { await store.inspect(item.id) } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                if tab != 3 && tab != 4 {
                    Button(saving ? "Applying…" : prepared ? "Download selected files" : "Apply changes") { apply() }
                        .buttonStyle(.borderedProminent).tint(.teal).disabled(saving || !store.ready)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 610)
            .onAppear {
                draft = item.configuration
                selectedFiles = Set(draft.selectedFiles ?? (item.fileDetails ?? []).filter(\.selected).map(\.id))
                if let date = draft.scheduledAt { scheduleEnabled = true; scheduledDate = date }
                tab = prepared ? 1 : store.inspectorTab
                Task { await store.inspect(item.id) }
            }
            .transferErrorAlert(store).interactiveDismissDisabled(saving)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Bandwidth") {
                VStack(spacing: 12) {
                    bandwidth("Download limit", value: $draft.downloadLimit)
                    bandwidth("Upload limit", value: $draft.uploadLimit)
                    Stepper("Connections: \(draft.connections)", value: $draft.connections, in: 1...16)
                    Text("0 means unlimited. Use 256K or 5M for a cap. The global limit also applies.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            if item.isTorrent {
                GroupBox("Sharing") {
                    VStack(alignment: .leading, spacing: 12) {
                        SeedPolicyFields(mode: $draft.seedMode, ratio: $draft.seedRatio, minutes: $draft.seedMinutes)
                        Text("Uploaded \(bytes(item.uploadedBytes ?? 0))  ·  Ratio \(item.shareRatio, specifier: "%.2f")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Pieces can upload while downloading. This setting controls seeding after completion.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }
            GroupBox("Organization and scheduling") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Queue"); TextField("Queue name", text: $draft.queue).textFieldStyle(.roundedBorder) }
                    Toggle("Start at a scheduled time", isOn: $scheduleEnabled)
                    if scheduleEnabled { DatePicker("Start", selection: $scheduledDate, in: Date()...).datePickerStyle(.field) }
                    Text("Scheduling runs while Extreme Download Manager is open. Scheduled downloads remain paused until their start time.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(selectedFiles.count) of \((item.fileDetails ?? []).count) files selected").font(.headline)
            HStack {
                Button("Select all") { selectedFiles = Set((item.fileDetails ?? []).map(\.id)) }
                Button("Select none") { selectedFiles.removeAll() }
                Spacer()
                Text(bytes((item.fileDetails ?? []).filter { selectedFiles.contains($0.id) }.reduce(0) { $0 + $1.length })).font(.caption.monospacedDigit())
            }
            ForEach(item.fileDetails ?? []) { file in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { selectedFiles.contains(file.id) }, set: { if $0 { selectedFiles.insert(file.id) } else { selectedFiles.remove(file.id) } })) { Text(file.path).font(.caption).lineLimit(2).truncationMode(.middle) }
                    Spacer()
                    Text(bytes(file.length)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
                Divider()
            }
            if item.fileDetails?.isEmpty != false { Text("Resolving file information. Use Refresh details once metadata is available.").foregroundStyle(.secondary) }
            Toggle("Prioritize the beginning and end for media preview", isOn: $draft.sequential)
            Text("Shared boundary pieces may include bytes from adjacent skipped files. Playback also depends on the media format and available pieces.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var peersPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Uploaded \(bytes(item.uploadedBytes ?? 0))  ·  \(bytes(item.uploadSpeed))/s  ·  Share ratio \(item.shareRatio, specifier: "%.2f")").font(.caption.monospacedDigit())
            if let hash = item.infoHash { Text("Info hash: \(hash)").font(.caption.monospaced()).textSelection(.enabled) }
            if let bitfield = item.bitfield, !bitfield.isEmpty {
                PieceMap(hex: bitfield, count: item.pieceCount ?? bitfield.count * 4).frame(height: 66)
                Text("Teal blocks summarize verified pieces available locally.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Peers").font(.headline)
            if store.servers.isEmpty { Text("No connected peers.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(store.servers.enumerated()), id: \.offset) { _, server in Text(server).font(.caption.monospaced()).textSelection(.enabled) }
            Text("Trackers").font(.headline)
            ForEach(Array((item.trackerURLs ?? []).enumerated()), id: \.offset) { _, tracker in Text(tracker).font(.caption).textSelection(.enabled) }
            if item.trackerURLs?.isEmpty != false { Text("No tracker URLs reported. Magnet discovery may use DHT and peer exchange.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var repairPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Replace an expired download link").font(.headline)
            TextField("Fresh HTTP or HTTPS download URL", text: $replacementURL).textFieldStyle(.roundedBorder)
            Picker("Recovery", selection: $keepProgress) {
                Text("Keep partial data if validators match").tag(true)
                Text("Start a separate file; keep the old partial file").tag(false)
            }.pickerStyle(.radioGroup)
            Text("Keeping partial data requires matching size and a strong ETag or Last-Modified value. If the server cannot establish identity, use a separate file.").font(.caption).foregroundStyle(.secondary)
            if !item.error.isEmpty { Text(item.error).font(.caption).foregroundStyle(.red); Text(TransferUtilities.guidance(for: item.error)).font(.caption) }
            Button(saving ? "Checking…" : "Check and repair") {
                saving = true
                Task { if await store.repair(item.id, source: replacementURL.trimmingCharacters(in: .whitespacesAndNewlines), keepProgress: keepProgress) { dismiss() }; saving = false }
            }.buttonStyle(.borderedProminent).tint(.teal).disabled(saving || replacementURL.isEmpty)
        }
    }

    private var integrityPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            if !item.isTorrent {
                Text("Expected SHA-256").font(.headline)
                TextField("Optional 64-character checksum", text: $draft.sha256).font(.caption.monospaced()).textFieldStyle(.roundedBorder)
                Text("Set this before or during a transfer to have the engine verify its output. Updating a checksum may restart the transfer.").font(.caption).foregroundStyle(.secondary)
                Button("Save expected checksum") { apply() }.disabled(saving)
                Button(store.verifyingIDs.contains(item.id) ? "Verifying…" : "Calculate / verify completed file") {
                    Task { await store.verifyChecksum(item.id) }
                }.disabled(item.status != "complete" || store.verifyingIDs.contains(item.id))
                if let result = item.verification { Text(result).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(result.hasPrefix("CHECKSUM MISMATCH") ? .red : .secondary) }
            } else {
                Text("Torrent piece verification").font(.headline)
                Text("The transfer engine checks torrent pieces against the torrent's hashes. Invalid pieces are rejected. The piece map shows available verified pieces.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func bandwidth(_ label: String, value: Binding<String>) -> some View {
        HStack { Text(label); Spacer(); TextField("0", text: value).textFieldStyle(.roundedBorder).frame(width: 100); Text("B/s").font(.caption).foregroundStyle(.secondary) }
    }

    private func apply() {
        draft.queue = draft.queue.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.queue.isEmpty { draft.queue = "Default" }
        draft.scheduledAt = scheduleEnabled ? scheduledDate : nil
        if item.isTorrent, item.fileDetails?.isEmpty == false { draft.selectedFiles = selectedFiles.sorted() }
        saving = true
        Task { if await store.saveControls(draft, id: item.id, start: prepared) { dismiss() }; saving = false }
    }
}

struct SeedPolicyFields: View {
    @Binding var mode: SeedMode
    @Binding var ratio: Double
    @Binding var minutes: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("After download", selection: $mode) { ForEach(SeedMode.allCases) { Text($0.title).tag($0) } }
            if mode == .ratio { HStack { Text("Target ratio"); TextField("2.0", value: $ratio, format: .number).textFieldStyle(.roundedBorder).frame(width: 90) } }
            if mode == .time { Stepper("Seed for \(minutes) minutes", value: $minutes, in: 1...525600, step: 15) }
        }
    }
}

struct PieceMap: View {
    let hex: String
    let count: Int
    var body: some View {
        Canvas { context, size in
            let bits = hex.flatMap { character -> [Bool] in guard let nibble = Int(String(character), radix: 16) else { return [] }; return (0..<4).map { nibble & (1 << (3 - $0)) != 0 } }
            let total = min(count, bits.count)
            guard total > 0 else { return }
            let cells = min(256, total), columns = 32
            let rows = Int(ceil(Double(cells) / Double(columns)))
            for cell in 0..<cells {
                let start = cell * total / cells, end = (cell + 1) * total / cells
                let present = bits[start..<end].filter { $0 }.count
                let proportion = Double(present) / Double(max(1, end - start))
                let rect = CGRect(x: Double(cell % columns) * size.width / 32, y: Double(cell / columns) * size.height / Double(rows), width: size.width / 32 - 2, height: size.height / Double(rows) - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(proportion > 0 ? .teal.opacity(0.2 + 0.8 * proportion) : .secondary.opacity(0.12)))
            }
        }.accessibilityLabel("Verified torrent piece availability")
    }
}

extension View {
    @MainActor func transferErrorAlert(_ store: DownloadStore) -> some View {
        alert("Extreme Download Manager", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
