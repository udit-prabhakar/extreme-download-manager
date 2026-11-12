import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.06, green: 0.55, blue: 0.49)
private let ink = Color.primary
private let canvas = Color(nsColor: .windowBackgroundColor)
private let surface = Color(nsColor: .textBackgroundColor)
private let line = Color.primary.opacity(0.07)

@MainActor
struct MainView: View {
    @ObservedObject var store: DownloadStore
    @State private var isDropTarget = false
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar.frame(width: 214)
                Rectangle().fill(line).frame(width: 1)
                VStack(spacing: 0) {
                    pageHeader
                    commandBar
                    downloadList
                    ActivityPanel(store: store)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .background(canvas)
        .foregroundStyle(ink)
        .frame(minWidth: 1020, minHeight: 680)
        .preferredColorScheme(store.preferences.extra.theme == "system" ? nil : store.preferences.extra.theme == "dark" ? .dark : .light)
        .sheet(isPresented: $store.showingAdd) { AddDownloadView(store: store) }
        .sheet(isPresented: $store.showingSettings) { PreferencesView(store: store) }
        .sheet(item: $store.editingTransfer) { TransferControlsView(store: store, initial: $0) }
        .sheet(isPresented: $store.showingBrowserInbox) { BrowserInboxView(store: store) }
        .sheet(isPresented: $store.showingHealth) { HealthView(store: store) }
        .alert("Extreme Download Manager", isPresented: Binding(get: { store.errorMessage != nil && !store.showingAdd && !store.showingSettings && !store.showingBrowserInbox && !store.showingHealth && store.editingTransfer == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onDrop(of: [UTType.url.identifier, UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: $isDropTarget, perform: receiveDrop)
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 12).stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(10).allowsHitTesting(false) } }
        .task { store.startBrowserInbox(); await store.start() }
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(accent.gradient).frame(width: 38, height: 38)
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("extreme").font(.system(size: 21, weight: .bold, design: .rounded)).tracking(-0.5)
                Text("DOWNLOAD MANAGER").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.showingBrowserInbox = true } label: {
                Label(store.browserCaptures.isEmpty ? "Browser links" : "Browser links (\(store.browserCaptures.count))", systemImage: "globe")
                    .font(.system(size: 11))
            }.help("Review browser links and set up browser integration")
            Button { store.showingHealth = true } label: { HStack(spacing: 6) {
                Circle().fill(store.ready ? accent : Color.orange).frame(width: 6, height: 6)
                Text(store.ready ? "Ready when you are" : store.engineMessage).font(.system(size: 11)).foregroundStyle(.secondary)
            } }.buttonStyle(.plain).help("Engine & storage")
            Button { store.showingSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 34, height: 34) }
                .buttonStyle(.plain).help("Preferences")
        }.padding(.horizontal, 24).padding(.vertical, 16).background(surface)
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12).padding(.top, 27)
            ForEach(DownloadFilter.allCases) { filter in
                Button { store.filter = filter; store.selection = nil; store.selectedIDs.removeAll() } label: {
                    HStack(spacing: 11) {
                        Image(systemName: filter.icon).font(.system(size: 16)).frame(width: 20)
                        Text(filter.rawValue).font(.system(size: 12, weight: store.filter == filter ? .semibold : .medium))
                        Spacer(minLength: 0)
                        Text("\(store.items.filter { filter.matches($0) }.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(store.filter == filter ? accent.opacity(0.12) : .black.opacity(0.04), in: Capsule())
                    }.padding(.horizontal, 13).padding(.vertical, 11)
                        .foregroundStyle(store.filter == filter ? accent : ink.opacity(0.7))
                        .background(store.filter == filter ? accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(accent); Text("Built for the big files").font(.system(size: 11, weight: .semibold)) }
                Text("Parallel connections.\nPick up where you left off.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                Divider().padding(.vertical, 3)
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: store.preferences.directory).lastPathComponent).lineLimit(1).font(.system(size: 11))
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: store.preferences.directory)) } label: { Image(systemName: "arrow.up.right").font(.system(size: 10)) }.buttonStyle(.plain).help("Open download folder")
                }
            }.padding(14).background(surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line)).padding(.bottom, 18)
            HStack { Text("EXTREME").font(.system(size: 9, weight: .bold)).tracking(1.5); Spacer(); Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0")).font(.system(size: 10)) }.foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.bottom, 12)
        }.padding(.horizontal, 12)
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.filter == .all ? "Your downloads, in order." : store.filter.rawValue).font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                Text("\(store.activeCount) active  ·  \(store.finishedCount) completed  ·  \(bytes(store.downloadedBytes)) transferred").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.showingAdd = true } label: {
                Label("New download", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 11)
            }.buttonStyle(.plain).foregroundStyle(.white).background(accent, in: RoundedRectangle(cornerRadius: 8)).disabled(!store.ready).keyboardShortcut("n")
        }.padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 22)
    }

    private var commandBar: some View {
        HStack(spacing: 6) {
            toolButton("play.fill", "Resume", "Resume selected or all paused downloads") {
                Task { await store.bulk("resume") }
            }.disabled(!store.ready || !(store.actionTargets.isEmpty ? store.items : store.actionTargets).contains { ["paused", "error"].contains($0.status) })
            toolButton("pause.fill", "Pause", "Pause selected or all downloads") {
                Task { await store.bulk("pause") }
            }.disabled(!store.ready || !(store.actionTargets.isEmpty ? store.items : store.actionTargets).contains { ["active", "waiting"].contains($0.status) })
            Rectangle().fill(line).frame(width: 1, height: 17).padding(.horizontal, 5)
            toolButton("doc.badge.plus", "Torrent", "Import a .torrent file") { store.importTorrent() }.disabled(!store.ready)
            toolButton("trash", "", "Remove selected download from the list; keep its files") { Task { await store.bulk("remove") } }.disabled(store.selectedItem == nil || !store.ready)
            Menu {
                Button("Select all visible") { store.selectAllVisible() }
                Button("Clear selection") { store.selectedIDs.removeAll(); store.selection = nil }
                Divider()
                Button("Download controls…") { if let item = store.selectedItem { store.showControls(item) } }.disabled(store.selectedItem == nil)
                Button("Move to front") { if let item = store.selectedItem { Task { await store.prioritize(item) } } }.disabled(store.selectedItem == nil)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            Menu {
                Button("All queues") { store.queueFilter = "" }
                ForEach(store.preferences.extra.queueNames, id: \.self) { queue in Button(queue) { store.queueFilter = queue } }
            } label: { Text(store.queueFilter.isEmpty ? "All queues" : store.queueFilter).font(.system(size: 10)) }.menuStyle(.borderlessButton).frame(width: 90)
            Spacer(minLength: 10)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search downloads", text: $store.search).textFieldStyle(.plain).font(.system(size: 11))
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(width: 190).background(surface, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(line))
        }.padding(.horizontal, 22).padding(.bottom, 14)
    }

    private func toolButton(_ icon: String, _ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11)); if !title.isEmpty { Text(title).font(.system(size: 11, weight: .medium)) } }
                .padding(.horizontal, 10).frame(height: 29)
        }.buttonStyle(.plain).help(help)
    }

    private var downloadList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("PROGRESS").frame(width: 155, alignment: .leading)
                Text("SPEED").frame(width: 75, alignment: .trailing)
                Text("REMAINING").frame(width: 70, alignment: .trailing)
                Color.clear.frame(width: 28)
            }.frame(height: 12).font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(.secondary)
                .padding(.horizontal, 23).padding(.vertical, 12).background(Color.white.opacity(0.7))
            Rectangle().fill(line).frame(height: 1)
            if store.visibleItems.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleItems) { item in
                            DownloadRow(item: item, selected: store.selectedIDs.contains(item.id) || store.selection == item.id, onSelect: { store.select(item.id, extending: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }, onToggle: {
                                Task { await store.perform(item.status == "active" || item.status == "waiting" ? "pause" : "resume", item: item) }
                            })
                            .contextMenu {
                                Button("Download controls…") { store.showControls(item) }
                                if !item.isTorrent { Button("Repair link…") { store.showControls(item, tab: 3) } }
                                if ["paused", "waiting"].contains(item.status) { Button("Move to front") { Task { await store.prioritize(item) } } }
                                if item.status == "complete" { Button("Open file") { store.open(item) } }
                                Button("Show in Finder") { store.reveal(item) }
                                Button("Copy source URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.source, forType: .string) }
                                if ["paused", "error"].contains(item.status) { Button("Resume / retry") { Task { await store.perform("resume", item: item) } } }
                                if ["active", "waiting"].contains(item.status) { Button("Pause") { Task { await store.perform("pause", item: item) } } }
                                Divider()
                                Button("Remove from list") { Task { await store.remove(item) } }
                            }
                            .onTapGesture(count: 2) { store.open(item) }
                        }
                    }
                }.background(surface)
            }
        }.background(surface).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(line))
            .padding(.horizontal, 24).padding(.bottom, 18).frame(minHeight: 230, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.055)).frame(width: 94, height: 94)
                Circle().stroke(accent.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 5])).frame(width: 76, height: 76)
                Image(systemName: store.search.isEmpty && store.filter == .all ? "arrow.down.to.line" : "tray").font(.system(size: 29, weight: .light)).foregroundStyle(accent)
            }
            Text(store.search.isEmpty && store.filter == .all ? "Make room for something good." : "Nothing here yet.").font(.system(size: 17, weight: .medium)).tracking(-0.3)
            Text(store.search.isEmpty && store.filter == .all ? "Paste a link, import a torrent, or drop one here.\nWe’ll take care of the heavy lifting." : "Downloads matching this view will appear here.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            if store.filter == .all && store.search.isEmpty {
                Button { store.showingAdd = true } label: { Label("Add your first download", systemImage: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent).padding(.horizontal, 15).padding(.vertical, 9).background(accent.opacity(0.07), in: Capsule()) }.buttonStyle(.plain).disabled(!store.ready).padding(.top, 2)
            }
        }.padding(25)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(store.ready ? accent : .orange).frame(width: 5, height: 5)
            Text(store.engineMessage)
            Spacer()
            Image(systemName: "arrow.down"); Text("\(bytes(store.totalSpeed))/s").monospacedDigit()
            Text("·").padding(.horizontal, 7)
            Image(systemName: "arrow.up"); Text("\(bytes(store.uploadSpeed))/s").monospacedDigit()
            Text("·").padding(.horizontal, 7)
            Text(store.preferences.speedLimit == "0" ? "No speed limit" : "Limit: \(store.preferences.speedLimit)/s")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 31).background(surface)
            .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in if url.pathExtension.lowercased() == "torrent" { store.importTorrent(url) } else { store.errorMessage = "Drop a .torrent file or a download URL." } }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }; Task { @MainActor in store.incomingURL = url.absoluteString; store.showingAdd = true }
            }
        } else {
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }; Task { @MainActor in store.incomingURL = value; store.showingAdd = true }
            }
        }
        return true
    }
}

@MainActor
struct DownloadRow: View {
    let item: DownloadItem
    let selected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    var color: Color { item.status == "error" ? .red : item.status == "paused" ? .orange : accent }
    var icon: String {
        if item.isTorrent { return "point.3.connected.trianglepath.dotted" }
        switch item.fileURL.pathExtension.lowercased() {
        case "zip", "rar", "7z", "gz": return "doc.zipper"
        case "mp4", "mkv", "mov", "webm": return "film"
        case "mp3", "flac", "wav": return "music.note"
        case "dmg", "pkg", "exe": return "shippingbox"
        case "pdf", "txt", "docx": return "doc.text"
        default: return "doc"
        }
    }
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(color).frame(width: 39, height: 43).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 4, height: 4)
                        Text(item.statusLabel).foregroundStyle(color)
                        Text("·").foregroundStyle(.tertiary)
                        Text(item.total > 0 ? bytes(item.total) : "Calculating size…").foregroundStyle(.secondary)
                    }.font(.system(size: 10))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(bytes(item.completed)).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.total > 0 ? "\(Int(item.progress * 100))%" : "—").foregroundStyle(color)
                }.font(.system(size: 10)).monospacedDigit()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.055))
                        Capsule().fill(color).frame(width: max(0, proxy.size.width * item.progress))
                    }
                }.frame(height: 4)
            }.frame(width: 155)
            Text(item.status == "active" ? "\(bytes(item.speed))/s" : "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(item.speed > 0 ? ink : .secondary).frame(width: 75, alignment: .trailing)
            Text(item.remaining).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Button(action: onToggle) {
                Image(systemName: item.status == "complete" ? "checkmark" : ["active", "waiting"].contains(item.status) ? "pause.fill" : "play.fill").font(.system(size: 11)).foregroundStyle(item.status == "complete" ? accent : .secondary).frame(width: 28, height: 28).background(.black.opacity(0.035), in: Circle())
            }.buttonStyle(.plain).disabled(item.status == "complete").help(["active", "waiting"].contains(item.status) ? "Pause" : "Resume")
        }.padding(.horizontal, 23).padding(.vertical, 17).background(selected ? accent.opacity(0.055) : surface)
            .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
            .contentShape(Rectangle()).onTapGesture(perform: onSelect)
    }
}

@MainActor
struct ActivityPanel: View {
    @ObservedObject var store: DownloadStore
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                HStack(spacing: 22) {
                    ForEach(["Activity", "Details", "Connections"].indices, id: \.self) { index in
                        Button { tab = index; if index == 2 { Task { await store.inspectConnections() } } } label: {
                            VStack(spacing: 9) {
                                Text(["Activity", "Details", "Connections"][index]).font(.system(size: 11, weight: tab == index ? .semibold : .regular)).foregroundStyle(tab == index ? ink : .secondary)
                                Rectangle().fill(tab == index ? accent : .clear).frame(height: 2)
                            }.frame(width: index == 2 ? 78 : 52)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                if let item = store.selectedItem { Text(item.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 250, alignment: .trailing) }
                else { Text("ALL DOWNLOADS").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(.tertiary) }
            }
            if tab == 0 {
                HStack(spacing: 25) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Download speed", systemImage: "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(bytes(store.totalSpeed)).font(.system(size: 27, weight: .light)).tracking(-1).monospacedDigit()
                            Text("/s").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text("Peak  \(bytes(store.peakSpeed))/s").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.frame(width: 145, alignment: .leading)
                    SpeedGraph(values: store.speedHistory).frame(height: 80)
                }
            } else if tab == 1, let item = store.selectedItem {
                VStack(alignment: .leading, spacing: 8) {
                    detail("Source", item.source)
                    detail("Save to", item.directory)
                    if item.isTorrent { detail("Uploaded", "\(bytes(item.uploadedBytes ?? 0))  ·  Ratio \(String(format: "%.2f", item.shareRatio))") }
                    detail("Queue", item.configuration.queue)
                    if let warning = item.quarantineError { Text(warning).font(.caption).foregroundStyle(.orange) }
                    detail("Transfer", "\(bytes(item.completed)) of \(item.total > 0 ? bytes(item.total) : "unknown size")  ·  \(item.connections) connections")
                    if !item.error.isEmpty { Text(item.error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            } else if tab == 2, store.selectedItem != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if store.servers.isEmpty { Text("No active connections for this download.").foregroundStyle(.secondary) }
                        ForEach(Array(store.servers.enumerated()), id: \.offset) { index, server in
                            HStack { Circle().fill(accent).frame(width: 4, height: 4); Text("\(index + 1).  \(server)").textSelection(.enabled) }
                        }
                    }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 80)
            } else { Text("Select a download to see its \(tab == 1 ? "details" : "connections").").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
        }.padding(.horizontal, 27).padding(.top, 3).padding(.bottom, 23)
            .onChange(of: store.selection) { _ in if tab == 2 { Task { await store.inspectConnections() } } }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary).frame(width: 60, alignment: .leading); Text(value).lineLimit(2).textSelection(.enabled) }.font(.system(size: 10))
    }
}

struct SpeedGraph: View {
    let values: [Double]
    var body: some View {
        Canvas { context, size in
            let maximum = max(values.max() ?? 0, 1024)
            for i in 0...3 {
                let y = Double(i) * size.height / 3
                var grid = Path(); grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(.black.opacity(0.045)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: Double(index) / Double(max(1, values.count - 1)) * size.width, y: size.height - value / maximum * (size.height - 6))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var fill = path; fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [accent.opacity(0.19), accent.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
        }.overlay(alignment: .bottomTrailing) { Text("LAST 48 SECONDS").font(.system(size: 7)).tracking(1).foregroundStyle(.tertiary).offset(y: 13) }
    }
}

@MainActor
struct AddDownloadView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var urls = ""
    @State private var directory = ""
    @State private var filename = ""
    @State private var submitting = false
    @State private var advanced = false
    @State private var configuration = DownloadConfiguration()
    @State private var scheduleEnabled = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 32)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) { Text("New download").font(.system(size: 22, weight: .semibold)); Text("A link is all you need.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("DOWNLOAD LINK").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                TextEditor(text: $urls).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(9).frame(height: 90).background(canvas, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(line))
                Text("HTTP, HTTPS, FTP, SFTP, or magnet links. One link per line for a batch.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("SAVE TO").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder").foregroundStyle(accent)
                    Text(directory).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { if let value = store.chooseFolder(current: directory) { directory = value } }
                }.padding(10).background(canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("File name (optional, single link only)", text: $filename).textFieldStyle(.roundedBorder).disabled(urls.split(whereSeparator: \.isNewline).count > 1)
            DisclosureGroup("Advanced options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text("Queue").font(.caption); TextField("Default", text: $configuration.queue).textFieldStyle(.roundedBorder) }
                    HStack { Text("Download limit").font(.caption); TextField("0 = unlimited; e.g. 1M", text: $configuration.downloadLimit).textFieldStyle(.roundedBorder) }
                    TextField("Expected SHA-256 (HTTP/FTP, optional)", text: $configuration.sha256).textFieldStyle(.roundedBorder).font(.caption.monospaced())
                    if urls.lowercased().contains("sftp:") {
                        TextField("Trusted SSH host-key SHA-1 fingerprint (40 hex characters)", text: Binding(get: { configuration.sshHostKeySHA1 ?? "" }, set: { configuration.sshHostKeySHA1 = $0 })).textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        Text("Get this fingerprint from the server administrator through a trusted channel.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Schedule for later", isOn: $scheduleEnabled)
                    if scheduleEnabled {
                        DatePicker("Start", selection: $scheduledDate, in: Date()...).datePickerStyle(.field)
                        Text("Keep the app open for scheduled starts.").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
            }.font(.caption)
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(accent)
                Text("Up to \(store.preferences.connections) connections per download").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack {
                Button("Import torrent…") { store.importTorrent(); dismiss() }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(submitting ? "Adding…" : scheduleEnabled ? "Schedule download" : store.preferences.autoStart ? "Download" : "Add to queue") {
                    configuration.scheduledAt = scheduleEnabled ? scheduledDate : nil
                    submitting = true
                    Task { if await store.addURLs(urls, directory: directory, filename: filename.trimmingCharacters(in: .whitespaces), configuration: configuration) { dismiss() }; submitting = false }
                }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction).disabled(urls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting || !store.ready)
            }
        }.padding(28).frame(width: 530).background(surface).foregroundStyle(ink)
            .transferErrorAlert(store).interactiveDismissDisabled(submitting)
            .onAppear {
                directory = store.preferences.directory
                configuration = .defaults(store.preferences)
                if !store.incomingURL.isEmpty { urls = store.incomingURL; store.incomingURL = "" }
                else if let clipboard = NSPasteboard.general.string(forType: .string), ["http://", "https://", "magnet:"].contains(where: { clipboard.hasPrefix($0) }) { urls = clipboard }
            }
    }
}

@MainActor
struct PreferencesView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppPreferences()
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            Text("Make it yours.").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
            Text("Download preferences").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, -16)
            VStack(alignment: .leading, spacing: 9) {
                Text("Default download folder").font(.system(size: 12, weight: .medium))
                HStack { Image(systemName: "folder").foregroundStyle(accent); Text(draft.directory).font(.system(size: 11)).lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose…") { if let value = store.chooseFolder(current: draft.directory) { draft.directory = value } } }.padding(10).background(canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            Stepper(value: $draft.concurrentDownloads, in: 1...10) { setting("Simultaneous downloads", "\(draft.concurrentDownloads)") }
            Stepper(value: $draft.connections, in: 1...16) { setting("Connections per download", "\(draft.connections)") }
            HStack { Text("Download speed limit").font(.system(size: 12)); Spacer(); Picker("", selection: $draft.speedLimit) { Text("Unlimited").tag("0"); Text("1 MB/s").tag("1M"); Text("5 MB/s").tag("5M"); Text("10 MB/s").tag("10M"); Text("25 MB/s").tag("25M") }.labelsHidden().frame(width: 150) }
            HStack { Text("Torrent upload limit").font(.system(size: 12)); Spacer(); TextField("0", text: $draft.extra.uploadLimit).textFieldStyle(.roundedBorder).frame(width: 110); Text("B/s").font(.caption).foregroundStyle(.secondary) }
            Text("0 is unlimited. A cap such as 256K limits uploads while downloading and seeding.").font(.caption).foregroundStyle(.secondary)
            SeedPolicyFields(mode: $draft.extra.seedMode, ratio: $draft.extra.seedRatio, minutes: $draft.extra.seedMinutes)
            Picker("Appearance", selection: $draft.extra.theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Toggle("Start new downloads automatically", isOn: $draft.autoStart).font(.system(size: 12)).tint(accent)
            Text("Connection and seeding defaults apply to new downloads. Use Download controls to change an existing transfer. Unfinished downloads reopen paused.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            HStack {
                Button("Open app data") { NSWorkspace.shared.open(store.dataDirectory) }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save preferences") { saving = true; Task { if await store.applyPreferences(draft) { dismiss() }; saving = false } }.buttonStyle(.borderedProminent).tint(accent).disabled(saving || !store.ready).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520).background(surface).foregroundStyle(ink).transferErrorAlert(store).onAppear { draft = store.preferences }
    }
    private func setting(_ name: String, _ value: String) -> some View { HStack { Text(name).font(.system(size: 12)); Spacer(); Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(accent).padding(.trailing, 10) } }
}
