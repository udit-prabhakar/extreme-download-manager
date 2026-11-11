# Validation

Verified locally on the development Mac on 2026-11-11.

## Browser handoff milestone

- Five Node.js extension tests passed for URL filtering, exclusion host boundaries, narrow permissions, manifest identity, message contents, and context-menu actions.
- The real Swift native host passed framed stdio tests for Chromium/Firefox caller arguments, extension allowlists, private file permissions, unsupported URL schemes, embedded credentials, protocol versions, malformed/truncated input, and oversized frames. Evidence: `.build/browser-host-rmipepph/`.
- The expanded transfer suite passed with isolated Chrome/Edge/Firefox registration/removal, review-before-download, paused preferences, request replay protection, dismissal, and a checksum-correct 24 MiB download. Evidence: `.build/integration-8iesg2yr/`.
- The release app built and passed plist and ad-hoc signature validation. Packaged extensions and the executable native host wrapper are included in the bundle.
- A real packaged host message woke the app in `.build/browser-ui-profile/`. Native UI checks verified the pending-link badge, review form, setup instructions, registration/removal under `.build/browser-ui-library/`, acceptance, and empty inbox afterward. `Browser UI verified.bin` completed with the expected checksum and its browser request ID persisted in SQLite. Quitting removed the engine's runtime configuration.

The extension logic tests use browser API fixtures; no extension was installed into the user's real browser profiles. Actual installed-extension behavior across Chrome, Edge, and Firefox, permanent/signed Firefox installation, store publication, automatic download capture, and authenticated request handoff remain unverified or unimplemented as described in the browser integration guide. The native-host-to-app path was exercised with genuine protocol frames and the built helper.

## Transfer controls and recovery milestone

The final expanded run passed all checks; local evidence is in `.build/integration-r4z0x3u1/`. The controlled peer received 524,288 verified bytes at 62,363 B/s under the 64K cap, and the HTTP fixture recorded 23 Range requests. The final release build, bundle plist, and ad-hoc signature checks also passed.

The expanded suite verifies the existing transfer/restart checks below plus:

- One-time JSON-to-SQLite migration, preserving IDs and intentionally deleted history.
- Single-profile ownership before an app reads or migrates shared history.
- Link repair that refuses changed resource validators, retains valid partial data and the app ID, and completes with the expected SHA-256.
- Scheduled starts, including recovery when the engine's scheduled job is missing.
- Torrent file selection and per-torrent upload options; enabling and disabling media-piece prioritization.
- A real loopback BitTorrent peer receiving and validating 512 KiB under a 64K upload cap.
- Uploaded-byte accounting and switching a completed torrent from sharing to stop-after-completion.
- Reopening SQLite history with completed transfers and torrent file choices retained; retrying a failed legacy entry without changing its app ID.

The release application was visually inspected in its isolated test profile. Preferences show upload limits, seeding policies, and appearance controls. Importing a generated two-file torrent opened paused in the file-selection sheet; deselecting one file updated the selected count and size. Quitting stopped the owned engine and removed its private runtime configuration. No public tracker or swarm was used.

The executable links Apple's system SQLite library. aria2 remains a separate dependency. Release builds are locally ad-hoc signed, not notarized distribution builds. GitHub CI results are reported separately from these local checks.

## Earlier baseline verification

Before the initial public GitHub push, the transfer suite, local torrent-integrity experiment, and release build were run again successfully from the relocated `macos/` directory. The corresponding local evidence is in `.build/integration-6ia70ef3/` and `.build/torrent-hello-mmipgu8u/`. Repository hygiene and workflow YAML syntax were also checked. GitHub CI results are reported separately by the repository's Actions checks.

- Optimized Swift release build completed without compiler warnings.
- App bundle plist passed `plutil -lint`.
- Ad-hoc app signature passed `codesign --verify --deep --strict`.
- Final executable is native arm64; bundle uses the locally installed aria2 1.37.0 engine.
- Final release window was visually inspected after the layout corrections.

The earlier engine integration run passed every baseline check. Evidence is in `.build/integration-72i6tz2e/`:

1. Private engine startup and authenticated local RPC.
2. Real download from a loopback HTTP fixture and concurrency queueing.
3. Pause with partial progress.
4. Shutdown/restart with the paused transfer and control file retained.
5. Resume and SHA-256 validation of all 25,165,824 bytes.
6. Queue-item removal.
7. HTTP 404 surfaced as a failed transfer.
8. Torrent metadata import without a public swarm connection.
9. Another restart: paused torrent retained; completed file not requeued.
10. Seven HTTP Range requests observed; requests after the restart all began at nonzero offsets.

The native UI was also exercised using the new-download dialog and folder chooser. `EDM local verification.bin` was downloaded into `.build/ui-downloads/`, its SHA-256 matched the deterministic fixture, and completed history survived quitting and reopening the final release. That profile is isolated under `.edm-data/`; normal launches use the user's Application Support directory.

No public torrent swarm, HTTPS/FTP/SFTP endpoint, browser extension, site-video extractor, or media converter was tested. The last three features are not implemented. See README for the full current scope.
