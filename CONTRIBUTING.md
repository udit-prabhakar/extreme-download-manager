# Contributing

Application source, build commands, and tests live under `macos/`. See its README for prerequisites and the roadmap for planned work. Check the existing implementation before claiming a feature is available.

## Development workflow

1. Start from current `main` and create a focused branch such as `feat/upload-controls` or `fix/session-recovery`.
2. Implement one coherent change. Update user documentation when behavior changes.
3. Run appropriate local checks. For transfer or state changes, run `cd macos && bash scripts/test.sh`. For app/build changes, also run `bash scripts/build.sh release` from `macos/`.
4. Review the diff for private URLs, secrets, generated files, and unrelated changes.
5. Commit using a descriptive conventional subject, for example `feat(torrent): add upload bandwidth controls`.
6. Push the branch and open a pull request. Include the behavior change, verification performed, and remaining limitations. Wait for CI before merging.

Keep commits reviewable. Commit and push validated logical milestones rather than every editor save. Draft PRs may contain incomplete work, but must state what remains and which checks have not passed.

## Verification

Prefer deterministic local servers and generated fixtures for transfer tests. Do not depend on public torrents, copyrighted sample media, personal accounts, or private files. Disable public peer discovery in isolated tests. Never label planned checks as executed or claim performance measurements that were not collected.

## Repository hygiene

Do not commit build caches, application profiles, download histories, `.aria2` files, downloaded binaries/media, tokens, private keys, signing identities, or recovered third-party assets. GitHub Actions publishes generated app archives as workflow artifacts rather than Git history.

The original application code uses MIT. Describe every new runtime dependency in `THIRD_PARTY_NOTICES.md` and preserve its own licensing requirements. Follow `SECURITY.md` for suspected vulnerabilities.
