# Extreme Download Manager

[![macOS CI](https://github.com/udit-prabhakar/extreme-download-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/udit-prabhakar/extreme-download-manager/actions/workflows/ci.yml)

A native macOS download manager built with SwiftUI and an isolated aria2 transfer engine. Download files and torrents, manage a queue, pause and resume transfers, and retain download history across restarts.

## Current capabilities

- Parallel downloads and configurable concurrency.
- HTTP/HTTPS/FTP/SFTP URL entry, URL batches, magnets, and torrent import through aria2.
- Pause/resume, restart recovery, speed limits, and completed history.
- Search and status filters, live activity graph, connection details, and Finder actions.
- Native URL/torrent dialogs, drag and drop, and configurable download destinations.
- Global/per-torrent upload limits, uploaded totals, and configurable seeding rules.
- Torrent file selection, peer/tracker details, verified-piece map, and media-piece prioritization.
- Per-download connection/bandwidth settings, named queue filters, bulk actions, and scheduled starts while the app is open.
- Resource-validator-based link repair, SHA-256 checks, stable download IDs, and transactional SQLite history with legacy migration.
- Explicit Chrome/Edge/Firefox link handoff extensions, a local review inbox, and per-site exclusions. Development setup is described in [browser integration](docs/BROWSER_INTEGRATION.md).

This is an early working application. Protocol support comes from aria2; local HTTP transfers and controlled local torrent uploads have been tested. Public-swarm behavior and every supported network protocol have not been independently verified. The roadmap distinguishes this implementation from remaining proposals.

## Build and run

Requires macOS 13+, Apple's command-line tools, Python 3, and aria2. The transfer engine is currently a separate installation.

```sh
brew install aria2
cd macos
bash scripts/build.sh
open "build/Extreme Download Manager.app"
```

The build script creates an optimized, locally ad-hoc signed application for the build machine's architecture. No Swift packages are downloaded. Public distribution signing/notarization and a bundled engine are planned.

## Test

```sh
cd macos
bash scripts/test.sh
```

Tests start a loopback fixture server, transfer 24 MiB, check concurrency, pause/restart/resume, verify SHA-256, exercise removal and HTTP failure handling, and import torrent metadata. They also exercise history migration, profile locking, scheduled transfers, link repair, file selection, upload caps against a real local peer, and seeding-policy changes. Public peer discovery is disabled during tests. Generated evidence stays in the ignored `.build/` directory.

Browser extension logic and native-message framing tests require Node.js 20+ in addition to the build dependencies. The suite also checks browser inbox review, deduplication, dismissal, and a real local download after acceptance. Browser store publication and permanent Firefox installation remain pending.

An additional isolated protocol experiment is available with `python3 Tests/torrent_hello_experiment.py`. It verifies that a real receiving client rejects a corrupted torrent piece; it does not contact public peers or change the application engine.

## Project layout

```text
macos/
  Sources/ExtremeDownloadManager/  Application and transfer-engine adapter
  Resources/                      App metadata
  Tests/                          Deterministic local test fixtures
  scripts/                        Build, icon generation, and test commands
  README.md                       Detailed usage and architecture
  ROADMAP.md                      Prioritized feature gaps and acceptance criteria
  VALIDATION.md                   Recorded local verification scope
.github/                          CI, dependency updates, and contribution templates
```

See [macOS usage](macos/README.md), [roadmap](macos/ROADMAP.md), [contribution guide](CONTRIBUTING.md), and [GitHub workflow](docs/GITHUB_WORKFLOW.md).

## Privacy and dependencies

The application has no required cloud account or application analytics service. Downloads connect to their chosen sources; torrent features can exchange data with trackers, DHT nodes, and peers. The local aria2 control endpoint uses a fresh token and loopback binding. Download history and URLs are stored locally.

The app is independently implemented. Recovered FDM assets, private download history, credentials, and local analysis artifacts are excluded from this repository. aria2 is a separately installed GPL-licensed program; see [third-party notices](THIRD_PARTY_NOTICES.md).

## License

Original project code is available under the [MIT license](LICENSE). Third-party programs retain their respective licenses.
