# Validation

Verified locally on the development Mac on 2026-11-11.

Before the initial public GitHub push, the transfer suite, local torrent-integrity experiment, and release build were run again successfully from the relocated `macos/` directory. The corresponding local evidence is in `.build/integration-6ia70ef3/` and `.build/torrent-hello-mmipgu8u/`. Repository hygiene and workflow YAML syntax were also checked. GitHub CI results are reported separately by the repository's Actions checks.

- Optimized Swift release build completed without compiler warnings.
- App bundle plist passed `plutil -lint`.
- Ad-hoc app signature passed `codesign --verify --deep --strict`.
- Final executable is native arm64; bundle uses the locally installed aria2 1.37.0 engine.
- Final release window was visually inspected after the layout corrections.

The final engine integration run passed every check. Evidence is in `.build/integration-72i6tz2e/`:

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
