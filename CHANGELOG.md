# Changelog

## Unreleased

- Add explicit Chrome/Edge/Firefox link handoff extensions, site exclusions, native-host registration/removal, and a local review inbox with destination choice and replay protection.
- Add browser message framing/allowlist, extension logic, registration, and reviewed-transfer integration tests.
- Add global/per-torrent upload limits, uploaded byte totals, share ratio, and configurable seeding policies.
- Add paused torrent import with file selection, peer/tracker inspection, and verified-piece visualization.
- Add per-download controls, queue labels/filtering, multiple selection, move-to-front, and scheduled starts while the app is open.
- Add validator-based link repair and SHA-256 verification controls.
- Preserve stable application IDs across retries and migrate history to a transactional SQLite database off the UI actor.
- Add engine profile locking, cached metadata polling, clearer error handling, and appearance preferences.
- Expand integration coverage to real controlled torrent uploads, policy changes, database migration/reopening, scheduling, and repair.
- Remaining work is tracked in `macos/ROADMAP.md`.

## 1.0.0 — Initial source baseline

- Native macOS SwiftUI download manager backed by a separate aria2 process.
- Parallel transfers, URL batches, torrent import, queue limits, pause/resume, history, and speed controls.
- Local HTTP transfer/recovery tests and torrent metadata validation.
- Build scripts, generated app icon, project documentation, and automated macOS CI.

This entry records the initial source baseline; it does not announce a notarized binary release.
