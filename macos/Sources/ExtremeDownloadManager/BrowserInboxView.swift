import SwiftUI
import AppKit

@MainActor
struct BrowserInboxView: View {
    @ObservedObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var directory = ""
    @State private var filename = ""
    @State private var adding = false
    @State private var showingSetup = false
    private var capture: BrowserCapture? { store.browserCaptures.first { $0.id == selected } ?? store.browserCaptures.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "globe").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading) { Text("Browser links").font(.title2.bold()); Text("Review a link before adding it to your downloads.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Browser setup…") { showingSetup = true }
            }
            if let error = store.browserInboxError { Text(error).font(.caption).foregroundStyle(.red) }
            if let capture {
                Picker("Pending links", selection: Binding(get: { capture.id }, set: { selected = $0; filename = "" })) {
                    ForEach(store.browserCaptures) { item in Text(item.title.isEmpty ? URL(string: item.url)?.host ?? "Magnet link" : item.title).tag(item.id) }
                }
                Text(capture.browser + " · " + capture.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text(capture.url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("The link itself is sent to its source when you add it. Browser cookies and credentials are not included.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder").foregroundStyle(.teal)
                    Text(directory).font(.caption).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { if let folder = store.chooseFolder(current: directory) { directory = folder } }
                }
                TextField("File name (optional)", text: $filename).textFieldStyle(.roundedBorder)
                Divider()
                HStack {
                    Button("Dismiss link") { Task { await store.dismissBrowserCapture(capture) } }.disabled(adding)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(adding)
                    Button(adding ? "Adding…" : store.preferences.autoStart ? "Download" : "Add paused") {
                        adding = true
                        Task {
                            if await store.acceptBrowserCapture(capture, directory: directory, filename: filename.trimmingCharacters(in: .whitespaces)) { filename = ""; selected = nil }
                            adding = false
                        }
                    }.buttonStyle(.borderedProminent).tint(.teal).disabled(adding || !store.ready).keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "link.badge.plus").font(.system(size: 36)).foregroundStyle(.teal)
                    Text("No browser links waiting").font(.headline)
                    Text("Use the extension’s Send to Extreme action on a link, or paste a URL in its popup.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 35)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }.padding(26).frame(width: 610).disabled(adding)
            .onAppear { directory = store.preferences.directory; Task { await store.refreshBrowserInbox() } }
            .sheet(isPresented: $showingSetup) { BrowserSetupView() }
            .transferErrorAlert(store).interactiveDismissDisabled(adding)
    }
}

@MainActor
struct BrowserSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var browser: IntegratedBrowser = .chrome
    @State private var status = ""
    @State private var error: String?
    private var app: URL { Bundle.main.bundleURL }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect your browser").font(.title2.bold())
            Text("Explicit link handoff for Chrome, Edge, and Firefox. Links wait for your review in the app.").font(.callout).foregroundStyle(.secondary)
            Picker("Browser", selection: $browser) { ForEach(IntegratedBrowser.allCases) { Text($0.rawValue).tag($0) } }
            Text("1. Keep the app in a permanent location, then register its bridge for the selected browser.").font(.callout)
            HStack {
                Button("Register browser bridge") { perform { try BrowserRegistration.install(browser, app: app) } }.buttonStyle(.borderedProminent).tint(.teal)
                Button("Remove registration") { perform { try BrowserRegistration.remove(browser) } }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Text(browser == .firefox ? "2. Open about:debugging → This Firefox → Load Temporary Add-on, and choose manifest.json in the Firefox extension folder. Temporary add-ons must be loaded again after restarting Firefox." : "2. Open \(browser == .edge ? "edge" : "chrome")://extensions, enable Developer mode, choose Load unpacked, and select the Chromium extension folder.").font(.callout)
            Button("Show extension folder") {
                if let folder = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtensions/" + browser.extensionFolder) { NSWorkspace.shared.open(folder) }
            }
            Text("3. Pin the extension, then right-click a link and choose Send to Extreme, or use its popup. You can exclude sites in the popup.").font(.callout)
            Text("The extension has no cookie, browsing-history, or automatic download-interception permission. The bridge uses local browser pipes; no listening server is added. Store publication and Safari support are still pending.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 570)
            .onAppear { refreshStatus() }.onChange(of: browser) { _ in refreshStatus() }
            .alert("Browser integration", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func refreshStatus() { status = BrowserRegistration.status(browser, app: app) }
    private func perform(_ action: () throws -> Void) { do { try action(); refreshStatus() } catch { self.error = error.localizedDescription } }
}
