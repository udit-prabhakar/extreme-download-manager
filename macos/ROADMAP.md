# Extreme Download Manager: feature gap review and roadmap

Reviewed the macOS source and official competitor documentation on 2026-11-11. This roadmap includes both implemented foundations and remaining work.

## Implementation status: transfer controls milestone

Implemented: global/per-torrent upload caps, uploaded totals, configurable seeding, torrent file selection, peer/tracker/piece inspection, per-download limits, queue labels and filtering, multi-selection, move-to-front, scheduled starts while open, validator-based URL repair, SHA-256 verification, stable app IDs, transactional history migration, and profile locking.

These are initial implementations, not closure of every priority row below. Full per-file priorities, broader authentication/recovery, browser capture, engine bundling/notarization, background time windows, media processing, and remote automation remain outstanding. Scheduling requires the app to stay open; queue labels do not yet define independent queue policies. See current usage and validation documents for exact behavior and test coverage.

## Product direction

Build a dependable native macOS download manager with convenient browser capture, recoverable transfers, transparent torrent controls, and a simple default interface. Offer advanced controls in inspectors and preferences. Evaluate success through completed, correct downloads and low user effort; parallel connections cannot exceed server, disk, or network limits.

## Current baseline

Implemented: native SwiftUI UI; isolated aria2 process; URL batches; HTTP-family transfer configuration; torrent/magnet entry; parallel connections; concurrency limit; pause/resume; restart persistence; global download limit; status filters; search; history; progress/speed/ETA graph; basic connection list; Finder actions.

Verified: local HTTP range transfers, partial transfer recovery after restart, output checksum, queue limit, removal, HTTP failure, paused torrent metadata import, completed-history retention, and actual UI download entry. Protocol support inherited from the engine is broader than the verified test coverage. Public torrent throughput, magnet discovery, authenticated websites, and HTTPS/FTP/SFTP transfers have not been integration-tested here.

## Competitor reference points

These are documented features, not independent performance measurements or endorsements:

| Reference | Useful capabilities to learn from |
|---|---|
| [IDM options](https://www.internetdownloadmanager.com/support/using_idm/options.html) | Browser capture, destination rules, proxy configuration, and site credentials. |
| [IDM resume guidance](https://http.internetdownloadmanager.com/register/new_faq/sites2_3.html) | Refresh an expired download address. |
| [FDM current features](https://www.freedownloadmanager.org/features.htm) | Scheduling, media preview/conversion, add-ons, traffic modes, and remote control. Its page separately labels legacy features; do not assume those are all current-version capabilities. |
| [qBittorrent](https://www.qbittorrent.org/) | Torrent content priorities, peer/tracker controls, sequential downloading, scheduler, RSS, and torrent creation. |
| [JDownloader LinkGrabber](https://jdownloader.org/knowledge/wiki/glossary/linkgrabber) | Collect, inspect, filter, and package links before downloading. |
| [JDownloader Packagizer](https://support.jdownloader.org/en/knowledgebase/article/what-is-the-packagizer) | Rules for filenames, grouping, and destinations. |
| [Neat Download Manager](https://www.neatdownloadmanager.com/index.php/en) | Dynamic transfer controls, browser handoff, expired-link renewal, and HLS segment handling. |

## Prioritized gaps

| Priority | Capability | Concrete scope and acceptance condition |
|---|---|---|
| P0 | Upload and seeding controls | Global/per-torrent upload caps; uploaded byte totals; ratio; configurable stop-after-completion, time, and ratio rules. Clearly distinguish unlimited, limited, and paused. Explain when uploads are active. Enforce caps in a controlled two-peer test. |
| P0 | Torrent file selection | Inspect files and sizes before starting; skip files; set priorities; recheck integrity; display trackers, peers, and availability. Verify selected-file behavior and explain shared boundary pieces. |
| P0 | Transfer repair | Replace expired URLs; preserve valid partial data only when resource identity is compatible; expose useful 401/403/404/429 and disk errors; honor retry delay and cancellation. Verify redirects, changed files, unsupported ranges, and expiring URLs with deterministic fixtures. |
| P0 | Browser capture | Chrome/Edge/Firefox native messaging first, then a Safari integration. Capture a clicked download with destination and selected request context. Provide per-site exclusions and an explicit action to send a link. Test authenticated handoff without exporting unrelated cookies. |
| P0 | Reliable installation | Ship the engine with compatible dependencies or provide an explicit managed setup. Sign/notarize the application and helper components, build/test supported architectures, and offer verified updates with rollback/recovery. A clean supported Mac must launch without Homebrew. |
| P0 | Recovery and storage | Transactional history, migrations, backups, engine reconnection, single-profile ownership, disk-full handling, missing/removable destination handling, and safe completion. Verify forced exit, interrupted writes, sleep/wake, and engine crashes. |
| P1 | Better queues | Multiple named queues; drag ordering; priority; multiple selection; per-item connection/speed limits; batch actions; per-host concurrency controls. Do not let one slow host stall unrelated jobs. |
| P1 | Scheduler and network policies | Start/pause windows, separate day/night bandwidth, data budgets, battery behavior, and optional launch-at-login/background operation. State clearly when scheduling requires the app to be running. |
| P1 | Authentication and proxies | Basic/Digest where supported, selected headers/referrer/cookie import, HTTP/SOCKS profiles, and Keychain-backed secrets. Keep sensitive request data out of routine diagnostics. Validate actual engine capabilities rather than promising every authentication scheme. |
| P1 | Media downloads | HLS and DASH handling, track/quality/subtitle selection, supported site extractors, audio-only output, FFmpeg merging, and preview when sufficient data exists. Restrict initial scope to supported non-DRM streams. |
| P1 | Link collector and file organization | Preview link status/name/size, extract URLs from pasted text, detect duplicates, group packages, tag downloads, and apply filename/type/domain destination rules. Permit review before a large batch starts. |
| P1 | Visible integrity tools | User-supplied SHA-256 checksums, verification results, torrent recheck action, and useful failure explanations. Test damaged downloads and checksum mismatch handling. |
| P1 | Native Mac polish | Notification actions, menu-bar controls, dock progress, Quick Look, accessibility/VoiceOver, keyboard navigation, dark mode, and optional prevention of idle sleep while transferring. |
| P2 | Automation | Watch folders, RSS rules, Shortcuts/App Intents, CLI, and a narrowly scoped local API. Make automation actions visible and disableable. |
| P2 | Remote control | Optional authenticated pairing and remote queue control with clear device revocation. Preserve a fully functional local-only mode. This is not simply exposing the engine's RPC port. |
| P2 | Torrent authoring | Create a torrent from chosen files with piece-size, tracker, and comment settings. Treat the torrent as a content manifest and retain integrity validation. |
| P2 | Post-download workflows | Optional archive extraction with destination/path checks, media conversion, verified move/rename, and explicit completion actions. Avoid surprising execution of downloaded files. |
| P2 | Mirrors and advanced sources | Metalink UI, mirror health/failover, and multi-source downloads only when identity/checksum validation establishes that sources represent the same content. |

P0 means essential to the intended daily-use product or a credible public release, rather than evidence that the existing prototype is unusable. P1 improves convenience and coverage. P2 expands the product after the foundation is dependable.

## Architecture work supported by the current code

1. **Separate app records from engine IDs.** Keep a stable application download ID across retries, torrent metadata transitions, and engine restarts. Represent source URLs, engine jobs, and completed files as distinct records.
2. **Extend transactional persistence.** History now uses incremental SQLite writes on a database actor with a legacy migration. Add future schema migrations, interrupted-write recovery checks, and backup/restore UI. Keep future authentication secrets in Keychain, separate from history.
3. **Measure polling cost.** Active statistics now use light polling with cached file metadata and terminal records. Large-queue paging and responsiveness benchmarks remain. Measure before choosing events/WebSockets versus polling.
4. **Keep disk/CPU work off the UI actor.** Large torrent reads, base64 encoding, history encoding, and future checksum/extraction work should not block interface interaction.
5. **Supervise engine lifecycle.** Add health reporting, reconnection/restart policy, cleanup verification, startup cancellation, and profile locking. Preserve private authenticated loopback control.
6. **Add an engine capability interface.** Expose supported features and version-specific limits. Retain aria2 for the first improvements. Evaluate a specialized torrent backend if advanced requirements cannot be met; do not rewrite a transfer engine merely to claim acceleration.
7. **Design explicit transfer states.** Resolving, queued, connecting, downloading, verifying, merging, paused, completed, failed, and seeding should have accurate actions, progress, and recovery paths.

## Proposed implementation sequence

### Release 1: control and reliability

Upload caps/totals/ratio, configurable seeding, torrent file selection, multi-select actions, per-item limits, and actionable errors. Expand tests to real local seeding between controlled peers, changed-resource resume, no-range servers, network loss, and disk failures. Bundle/install and update the engine reliably before public distribution.

### Release 2: everyday convenience

Browser native messaging, authenticated-download handoff, expired-link repair, named queues, scheduler, notification actions, and sorting/tag rules. Test browser permission boundaries and transfer context along with download completion.

### Release 3: media and automation

Supported HLS/DASH workflows, track selection, FFmpeg processing, link collection, RSS/Shortcuts/watch folders, and optional remote pairing. Maintain plugins separately so site changes do not require a full app rewrite.

## Potential differentiators

These are product proposals, not claims that no competitor offers them:

- A per-download explanation of connection count, server restrictions, and why a transfer cannot resume.
- A clear transfer ledger: bytes downloaded/uploaded, hashes verified, sources and peer connections, with secrets redacted.
- One repair workflow that distinguishes expired URL, expired authorization, changed resource, missing destination, and disk-full conditions.
- Network presets that balance torrent uploads, ordinary downloads, responsiveness, and data budgets.
- Predictable behavior: no adware, no required cloud account, explicit telemetry choices, and understandable background activity.

## Release quality measurements

Track completion correctness, recoverable progress after interruption, time to recover a failed transfer, p95 UI responsiveness, memory/CPU with large histories, startup time, and idle network activity. Benchmark fixed fixtures and representative servers against competitors under equivalent limits. Do not make generic “N times faster” claims from parallel-connection counts alone.
