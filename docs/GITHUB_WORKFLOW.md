# GitHub development workflow

Repository: `https://github.com/udit-prabhakar/extreme-download-manager`

Use HTTPS authentication through GitHub CLI. Never put access tokens in repository URLs, tracked files, issue bodies, logs, or chat messages.

## Normal feature cycle

```sh
git switch main
git pull --ff-only
git switch -c feat/short-feature-name
# Implement a focused change.
cd macos
bash scripts/test.sh
bash scripts/build.sh release
cd ..
git diff --check
git add <explicit-source-and-documentation-paths>
git diff --cached --stat
git diff --cached
git commit -m "feat(area): describe the user-visible behavior"
git push -u origin HEAD
gh pr create --fill
gh pr checks --watch
```

Write or review the PR description before requesting review. State what changed, how it was tested, and any remaining limitations. Merge only after the required checks pass; use a squash merge for a coherent feature history. Update `CHANGELOG.md` when a change is user-facing.

The first source baseline is pushed to `main` before its protection settings are applied. Later changes should go through branches and pull requests. Repository settings and the current check status are authoritative; do not bypass protections merely because a local build passed.

## CI

The CI workflow builds and tests on macOS, runs the isolated torrent integrity experiment, creates a release app archive, and uploads it as a workflow artifact. It uses read-only repository permissions and pins third-party actions to specific commits. Dependabot proposes action updates through PRs.

Workflow artifacts are development builds. A public versioned release requires a deliberate release decision, version/changelog updates, and documented signing/distribution status. Do not represent an ad-hoc signed artifact as notarized.
