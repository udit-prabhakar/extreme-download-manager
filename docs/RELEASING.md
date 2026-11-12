# Release engineering and remaining public-release gates

The release candidate includes a relocatable engine and release verification tooling. It is not yet a notarized public product. The owner currently has no Apple Developer Program membership, so credentials and Apple submission are deliberately not configured.

## Build and validate locally

Prerequisites: a native Apple Silicon or Intel Mac, Apple's command-line tools, Python 3.12+, and pkg-config. Node.js 20+ is needed for extension tests. Debug integration tests can use a locally installed aria2; the release app always uses its bundled engine.

```sh
cd macos
bash scripts/build.sh release
python3 scripts/verify_bundle.py "build/Extreme Download Manager.app" --development
python3 Tests/test_packaged_app.py
EDM_ARIA2_PATH="$PWD/build/Extreme Download Manager.app/Contents/Resources/aria2c" bash scripts/test.sh
python3 scripts/package_distribution.py "build/Extreme Download Manager.app" --development
```

Initial builds fetch checksum-pinned sources, apply verified patches with zero fuzz, and build static non-system dependencies. An exclusive build lock prevents overlapping builds from modifying the same source tree. The build uses an isolated prefix under `.build/`, never installs globally, and validates its cache before reuse. The application bundle is staged and verified before replacing the previous local build.

Output is a development ZIP and SHA-256 file under `macos/build/distributions/`. The ZIP contains the app, notices, source archives, exact engine build script, security patches, rebuild instructions, component inventory, and file checksums. The engine has system-only dynamic linkage, so end users do not need Homebrew. Apple Silicon and Intel packages are separate; select the matching architecture. The minimum build target is macOS 13. A minimum-version hardware test is still required before asserting full support for that version.

The native app, native browser launcher, and engine use hardened runtime. Nested executables are signed before the app. Without a Developer ID identity, signing is ad-hoc and the package is explicitly marked development. Do not ask users to disable Gatekeeper or remove quarantine to treat it as a public release.

## Public release once an Apple account is available

1. Enroll in the Apple Developer Program and create/install a Developer ID Application identity through Apple's tooling. Keep its private key in Keychain or a protected CI signing store; do not put certificates, private keys, passwords, or account tokens in this repository or chat.
2. Configure an existing `notarytool` Keychain profile using Apple's supported authentication process. The release scripts accept the profile's name, never a password argument.
3. Start from a clean, committed, tested checkout. Set `EDM_SIGNING_IDENTITY` to the installed **Developer ID Application:** identity, `EDM_TEAM_ID` to its 10-character Apple team identifier, and `EDM_NOTARY_PROFILE` to the Keychain profile name, then run `bash macos/scripts/release.sh`.
4. The command builds/signs, submits to Apple's notary service, requires an **Accepted** result, staples the ticket, checks Gatekeeper acceptance, and only then packages a public distribution with corresponding source and checksums. Missing credentials, dirty source, unsigned code, mismatched architecture/minimum OS, external runtime libraries, missing sources, tampering, and absent notarization cause refusal.
5. Test the downloaded artifact on clean Gatekeeper-enabled Macs before publishing. Check first launch, destination selection, HTTP/HTTPS, torrent controls, restart/recovery, browser registration, and uninstall. Include the oldest supported OS and both architectures. Preserve the signed/notarized artifact and its checksum; do not modify the app after notarization.

Apple references: [Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), and [workflow customization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Compatibility and regression checks

CI builds/tests on macOS 15 for Apple Silicon and Intel. A single required check succeeds only after both platform jobs pass. Each job builds the native bundle, checks relocation/TLS/parser behavior, runs transfers and the torrent-integrity experiment against the bundled engine, verifies signing/architecture/linkage/minimum versions, and creates a development source-complete distribution. PR checks do not perform Apple notarization or publish a public release.

The recovery suite terminates only its owned fixture engine, verifies stable transfer IDs, correct completed bytes, paused-job preservation, bounded failures, retained profile ownership, manual retry, and runtime-secret cleanup. Storage tests cover corrupt and newer-schema refusal, duplicate-record rejection, and consistent backup restoration with preserved original files.

## Dependency maintenance

`EngineSources.lock.json` pins source archives and security patches; `EnginePatches/README.md` documents local backports and upstream provenance. Review upstream advisories before each release. A pinned latest tarball alone is insufficient when security fixes exist only as backports. Do not suppress version-based vulnerability findings globally; compare them to the recorded patch set and reproduce the affected behavior where practical.

When updating dependencies, review the diff and license changes, verify new checksums from upstream, rebuild from clean sources, run the full suite and package checks, and retain matching corresponding sources. The SPDX inventory records base versions and applied advisory IDs; it is an inventory, not an independent security certification. This project has not undergone an external security audit.

## Operational limits still requiring work or external validation

- Developer ID signing, notarization, clean-machine Gatekeeper acceptance, and oldest-supported-OS hardware validation remain public-release gates.
- Browser extensions still need development loading; store publication/signing and actual installed-browser testing are separate tasks. Core app downloading does not require the extensions.
- Public swarm throughput/discovery and real FTP/SFTP endpoints have not been covered by the deterministic local suite. SFTP support is compiled into the engine, not a claim that every server/authentication method was tested.
- Automatic updates, media extraction/conversion, background scheduling while closed, remote control, and other roadmap features are not implemented.
- SQLite backups refresh at most hourly; restoring can omit newer history entries. Downloaded/partial files are retained. Corrupt originals are preserved, not discarded automatically.

Manual updates currently mean quitting the app and replacing the complete bundle. Keep a profile backup before upgrades; newer history schemas are refused by older versions rather than silently downgraded. Browser host registration must be repaired if the app's installed path changes.

SFTP transfers require a trusted SSH host-key SHA-1 fingerprint in Advanced options or Download controls. This is the digest format supported by aria2; supply 40 hexadecimal characters, optionally colon-separated, obtained independently from the server administrator. Missing pins are refused, including on resumed legacy jobs. Host-key pinning does not provide a credentials manager or prove compatibility with every SSH server.

Completed downloaded files receive macOS quarantine metadata, and the app ensures it is present before opening a file. Existing quarantine metadata is preserved. Private source URLs are not copied into these attributes. If the destination cannot retain the metadata, the app reports the problem and offers Finder review rather than silently bypassing the check. This marker is not a malware scan.
