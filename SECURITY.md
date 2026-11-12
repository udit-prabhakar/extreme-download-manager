# Security policy

Security fixes target the latest source on `main`. Current development artifacts are locally ad-hoc signed with hardened runtime; they are not notarized public distributions. Public-release tooling requires Developer ID signing, an accepted notarization, a stapled ticket, and Gatekeeper acceptance.

Report a suspected vulnerability using **Security → Report a vulnerability** in this GitHub repository when private reporting is available. If it is unavailable, use an issue only to request a private reporting channel; do not post credentials, private download URLs, personal files, or exploit details publicly.

Useful reports describe the affected commit, operating system, aria2 version, operation, observed impact, and a minimal reproduction using non-sensitive fixtures. A complete exploit is not required.

The app invokes aria2 with the local account's permissions. Its RPC endpoint is intended to remain authenticated and bound to loopback. Target URLs, torrent files, peer content, downloaded files, and remote response data are untrusted. Treat unexpected command execution, path traversal, credential disclosure, or unauthorized control access as security concerns.

Review download sources and third-party engine updates independently. The MIT license does not provide a security warranty.

Bundled source versions and reviewed security backports are pinned in `macos/EngineSources.lock.json`. The distribution includes an SPDX inventory and corresponding engine sources/patches. A base-version scanner finding should be assessed against the recorded backports, not globally suppressed. These controls are not a substitute for independent security review. See `docs/RELEASING.md` for remaining release gates and maintenance procedures.
