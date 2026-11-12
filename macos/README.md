# Extreme Download Manager

A native macOS download manager with a SwiftUI interface and an isolated aria2 transfer engine. Inspired by the workflow investigated in Free Download Manager; the application is independently implemented and does not embed FDM code, artwork, or binaries.

The complete project lives in `macos/`. Run the commands below from that directory.

## Launch

The built application is at **`build/Extreme Download Manager.app`**. Double-click it in Finder, or run:

```sh
open "build/Extreme Download Manager.app"
```

Targets macOS 13 or newer. Release builds include a source-built `aria2c`; end users do not need Homebrew. Release apps use the bundled engine and refuse startup if it is missing. Debug builds can use `EDM_ARIA2_PATH`, `/opt/homebrew/bin/aria2c`, or `/usr/local/bin/aria2c` for development.

## Features

- HTTP, HTTPS, FTP, SFTP, magnet links, and `.torrent` import through aria2.
- Multiple parallel connections per download, configurable from 1 to 16.
- A concurrency-limited queue, pause/resume, retries, and restart recovery.
- Batch URL entry: one URL per line.
- All, downloading, queued, paused, completed, and failed views with search.
- Download size, progress, speed, ETA, live speed graph, and connection details.
- Destination selection, optional file naming, global speed limits, and automatic-start preferences.
- Completed download history, Finder reveal, opening completed files, and source URL copying.
- Drag-and-drop links or torrent files, plus native torrent/magnet document handling.
- Separate application settings and engine session files. Unfinished downloads reopen paused; completed entries stay in history.
- Global and per-torrent upload caps, cumulative uploaded bytes, share ratio, and stop/ratio/time/unlimited seeding policies.
- Torrent import pauses before transfer so you can choose files. The inspector exposes peers, trackers, and verified piece availability.
- Per-download limits, queue labels/filters, multiple selection, move-to-front, and scheduled starts while the app stays open.
- Compatible expired-link repair, expected SHA-256 and completed-file verification, and light/dark/system appearance.
- Transactional SQLite history, retained legacy JSON backup, stable identities across retries, and single-profile engine locking.
- Explicit browser link handoff for Chrome/Edge/Firefox, with a review inbox, destination choice, and excluded sites. See [browser setup](../docs/BROWSER_INTEGRATION.md).

Press **⌘N** to add a download, **⌘O** to import a torrent, and **⌘,** for preferences. Command-click rows to select several downloads, or use the toolbar selection menu. Resume/Pause acts on selected items, or all applicable items when nothing is selected. Removing an item keeps its files. Right-click for **Download controls** or **Repair link**.

Preferences set the global upload cap and seeding defaults for new transfers. **0 means unlimited bandwidth**, not zero uploading. The default seeding policy stops at completion; the other policies deliberately keep sharing. Uploads can occur during downloading under every seeding policy. Per-download caps and policies are available in Download controls.

Torrent imports open a file-selection sheet before transfer starts. Select at least one file and choose **Download selected files**. Shared boundary pieces can contain bytes from neighboring skipped files. Media prioritization requests beginning/end pieces; it does not guarantee playback or supply a built-in player.

SFTP requires a trusted SSH host-key SHA-1 fingerprint in Advanced options or Download controls. Supply 40 hexadecimal characters (optional colon separators) obtained independently from the server administrator. Unpinned SFTP starts/resumes are refused. This does not add a credentials manager or replace server-specific testing.

For scheduling, open Advanced options when adding a link, or use Download controls. **The app must remain open** for the scheduled start. Named queues organize/filter transfers; they do not have separate concurrency or time-window policies yet.

Repairing a link while preserving data requires matching resource size and strong ETag or Last-Modified validators. Conflicting validators are refused. When the source cannot establish compatibility, choose **Start a separate file** to retain the old partial data. Expected checksums add an independent content-integrity check.

Completed files are marked for macOS quarantine handling. The app checks this metadata before opening files and preserves any existing marker. Private download URLs are not added to file attributes.

Open **Downloads → Engine & storage** (or click the connection indicator) for retry and recovery controls. The app attempts up to three engine recoveries and retains the profile lock. Previously active jobs resume while paused jobs remain paused. Manual retry is available after correcting a startup problem. Engine logs rotate at startup when larger than 1 MiB. Newer history schemas and corrupt databases are refused without automatic replacement.

A standalone `history-backup.sqlite` is refreshed at most hourly during history saves. Restore can lose newer history entries and preserves original database/WAL files under `Preserved history/`; downloaded and partial files remain untouched. Backups contain private source URLs and stay local.

## Build from source

Uses Apple's command-line tools, Swift, Python 3.12+, pkg-config, and macOS frameworks. No Swift package downloads are needed. Release builds compile checksum-pinned aria2, OpenSSL, and libssh2 sources with reviewed security backports. The engine build is serialized by a file lock and cached after verification. Initial compilation takes several minutes; nothing is installed globally.

```sh
bash scripts/build.sh
```

This creates an optimized, locally ad-hoc signed `.app` bundle with hardened runtime for the build machine's architecture. The native browser launcher and engine are signed before the outer bundle. All non-system engine dependencies are statically linked. This development build is not a notarized public distribution; [release tooling](../docs/RELEASING.md) refuses to package it as one.

For a development build:

```sh
bash scripts/build.sh debug
```

## Architecture

| Source | Responsibility |
|---|---|
| `Sources/ExtremeDownloadManager/Views.swift` | Native library, transfer rows, graph, dialogs, and preferences. |
| `DownloadStore.swift` | App state, filtering, actions, history, and polling. |
| `Engine.swift` | Owned aria2 subprocess and authenticated JSON-RPC client. |
| `Models.swift` | Transfer metadata and presentation values. |
| `HistoryDatabase.swift` | Off-main-actor transactional SQLite history and one-time legacy migration. |
| `TransferControlsView.swift` | Per-download, torrent file/peer, scheduling, repair, and integrity controls. |
| `TransferUtilities.swift` | Resource validator probing, background checksums, and recovery explanations. |
| `BrowserBridge.swift`, `BrowserRegistration.swift`, `BrowserInboxView.swift` | Native messaging, per-user browser registration, and review/setup screens. |
| `HealthView.swift` | Engine capabilities, connection recovery, disk space, and history restore. |
| `DownloadedFileSecurity.swift` | macOS quarantine metadata for completed files and checks before opening. |
| `App.swift` | App lifecycle, menu commands, and document handling. |
| `EngineSelfTest.swift` | Explicit CLI-only transfer integration test. |

The app starts its own aria2 process, uses an ephemeral loopback RPC port with a random authentication token, and stops the owned engine on quit. An engine parent-process check also stops it if the app exits unexpectedly. Tokens are stored in a private config file, not command-line arguments. The app does not attach to or change another aria2 instance.

The [aria2 RPC documentation](https://aria2.github.io/manual/en/html/aria2c.html#rpc-interface) describes the transfer engine's underlying protocol.

## Data and connections

Normal app data lives in `~/Library/Application Support/Extreme Download Manager/`: preferences, `history.sqlite` and its WAL files, engine session/control metadata, and a log. Existing `history.json` records are imported once; the original and `history-v1-backup.json` are retained. Keep SQLite WAL files together with the database when inspecting or backing up a live profile. Download destinations default to `~/Downloads`. Download URLs can contain private information; history/session files are local. Folders are created with private permissions. The `.aria2` control files beside incomplete downloads are needed for reliable resume.

There is no application analytics service, vendor reporting endpoint, cloud account, or automatic updater. Network connections are made by downloads and torrent features. BitTorrent can contact trackers, DHT nodes, and peers; the app's local RPC connection is separate from those transfers. The engine verifies HTTPS certificates and does not automatically import browser cookies or `.netrc` credentials.

Development overrides:

```sh
EDM_DATA_DIR="$PWD/.edm-data" \
EDM_OFFLINE_TEST=1 \
"build/Extreme Download Manager.app/Contents/MacOS/ExtremeDownloadManager"
```

`EDM_OFFLINE_TEST=1` disables DHT and peer exchange for isolated testing. It does not block outbound HTTP URLs; the test suite supplies only a loopback server and controlled loopback peers.

## Verification

Build and run the local integration suite:

```sh
bash scripts/test.sh
```

Tests require Node.js 20+ in addition to Swift, Python, and aria2. They cover browser exclusion/URL logic, real native-host framing, isolated Chrome/Edge/Firefox registrations, review-before-download, request deduplication, and dismissal. The transfer suite tests real HTTP transfer/recovery, checksums, queue behavior, error handling, history migration/reopening, profile locking, link repair, scheduled starts, torrent file selection, a capped upload to a real local peer, and changing a seeding policy. It verifies nonzero resume offsets and that completed files are not requeued. Public peer discovery is disabled, and no public swarm is used. Evidence stays under `.build/integration-*` and `.build/browser-host-*`.

A download was also added through the actual native dialog, saved to a project test folder, verified by SHA-256, and confirmed in persisted completed history after quitting the app.

## Current boundaries

This is a working FDM-style download manager, not full feature parity with FDM. Automatic browser interception, authenticated browser request handoff, Safari integration, store-published extensions, site-specific video extraction, media conversion, background scheduling while closed, custom authentication/header dialogs, torrent creation, remote control, and advanced per-file priorities are not implemented. Browser extensions currently require development loading; Firefox temporary installs expire on restart. Ordinary downloadable media URLs work. Local HTTP/HTTPS and controlled torrent exchanges have integration coverage; live FTP/SFTP, public magnet discovery, and public-swarm performance remain unverified. The minimum target is macOS 13, but an oldest-supported-OS hardware smoke test remains a release acceptance task. Developer ID signing/notarization and browser store distribution are not completed.

The pre-existing reverse-engineering notes under `analysis/fdm` are reference artifacts and are not part of the application build. aria2 is a separate GPL-licensed program; distributions include its sources, build recipe, patches, and notices alongside the app.
