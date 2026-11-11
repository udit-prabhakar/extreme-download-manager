# Extreme Download Manager

A native macOS download manager with a SwiftUI interface and an isolated aria2 transfer engine. Inspired by the workflow investigated in Free Download Manager; the application is independently implemented and does not embed FDM code, artwork, or binaries.

The complete project lives in `macos/`. Run the commands below from that directory.

## Launch

The built application is at **`build/Extreme Download Manager.app`**. Double-click it in Finder, or run:

```sh
open "build/Extreme Download Manager.app"
```

Requires macOS 13 or newer and a local `aria2c` executable. aria2 is already installed on the development Mac. The app checks its resources, `/opt/homebrew/bin/aria2c`, and `/usr/local/bin/aria2c`. On another Mac, install the engine using `brew install aria2`, or supply its absolute path through `EDM_ARIA2_PATH`.

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

Press **⌘N** to add a download, **⌘O** to import a torrent, and **⌘,** for preferences. Resume/Pause acts on the selected item, or on all applicable items when nothing is selected. Removing an item from the list stops it and keeps its downloaded files. Right-click a download for additional actions. Torrent uploads stop when the download completes; uploads can occur while downloading.

## Build from source

Uses Apple's command-line tools, Swift, Python 3, and macOS frameworks. No Swift package downloads are needed.

```sh
bash scripts/build.sh
```

This creates an optimized, locally ad-hoc signed `.app` bundle for the build machine's architecture. It is not a notarized public distribution. aria2 remains a separately installed dependency rather than a copied Homebrew executable with unresolved dynamic libraries.

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
| `App.swift` | App lifecycle, menu commands, and document handling. |
| `EngineSelfTest.swift` | Explicit CLI-only transfer integration test. |

The app starts its own aria2 process, uses an ephemeral loopback RPC port with a random authentication token, and stops the owned engine on quit. An engine parent-process check also stops it if the app exits unexpectedly. Tokens are stored in a private config file, not command-line arguments. The app does not attach to or change another aria2 instance.

The [aria2 RPC documentation](https://aria2.github.io/manual/en/html/aria2c.html#rpc-interface) describes the transfer engine's underlying protocol.

## Data and connections

Normal app data lives in `~/Library/Application Support/Extreme Download Manager/`: preferences, download history, engine session/control metadata, and an engine log. Download destinations default to `~/Downloads`. Download URLs can contain private information; history/session files are local. Folders are created with private permissions. The `.aria2` control files beside incomplete downloads are needed for reliable resume.

There is no application analytics service, vendor reporting endpoint, cloud account, or automatic updater. Network connections are made by downloads and torrent features. BitTorrent can contact trackers, DHT nodes, and peers; the app's local RPC connection is separate from those transfers. The engine verifies HTTPS certificates and does not automatically import browser cookies or `.netrc` credentials.

Development overrides:

```sh
EDM_DATA_DIR="$PWD/.edm-data" \
EDM_OFFLINE_TEST=1 \
"build/Extreme Download Manager.app/Contents/MacOS/ExtremeDownloadManager"
```

`EDM_OFFLINE_TEST=1` disables DHT for isolated testing. It does not block outbound HTTP URLs; the test suite supplies only a loopback server.

## Verification

Build and run the local integration suite:

```sh
bash scripts/test.sh
```

It starts a deterministic loopback-only range server and tests an actual 24 MiB download, concurrency queueing, pause, engine restart, resume, SHA-256 integrity, removal, HTTP failures, and paused torrent metadata import. It verifies that requests after restart use nonzero byte offsets and that completed files are not requeued. DHT is disabled, and no public torrent swarm is used. Run evidence is retained under `.build/integration-*`.

A download was also added through the actual native dialog, saved to a project test folder, verified by SHA-256, and confirmed in persisted completed history after quitting the app.

## Current boundaries

This is a working FDM-style download manager, not full feature parity with FDM. Browser interception/extensions, site-specific video extraction, media conversion, timed scheduling, custom authentication/header dialogs, and selective torrent-file controls are not implemented. Ordinary downloadable media URLs work. Network protocols beyond local HTTP and torrent metadata parsing have not been integration-tested here. Torrent swarm throughput and magnet discovery have not been tested against public peers.

The pre-existing reverse-engineering notes under `analysis/fdm` are reference artifacts and are not part of the application build. aria2 is a separate GPL-licensed program; see its project for its license and source.
