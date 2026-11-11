# Security policy

Security fixes currently target the latest source on `main`. This early application is locally built and ad-hoc signed; it is not yet a notarized public distribution.

Report a suspected vulnerability using **Security → Report a vulnerability** in this GitHub repository when private reporting is available. If it is unavailable, use an issue only to request a private reporting channel; do not post credentials, private download URLs, personal files, or exploit details publicly.

Useful reports describe the affected commit, operating system, aria2 version, operation, observed impact, and a minimal reproduction using non-sensitive fixtures. A complete exploit is not required.

The app invokes aria2 with the local account's permissions. Its RPC endpoint is intended to remain authenticated and bound to loopback. Target URLs, torrent files, peer content, downloaded files, and remote response data are untrusted. Treat unexpected command execution, path traversal, credential disclosure, or unauthorized control access as security concerns.

Review download sources and third-party engine updates independently. The MIT license does not provide a security warranty.
