# Third-party notices

Original application code is MIT licensed. Bundled programs and their components retain their own licenses.

## Bundled engine

Release builds launch a separate, source-built aria2 process. Non-system OpenSSL and libssh2 dependencies are statically linked into that executable. Source versions, checksums, security backports, and provenance are recorded in `macos/EngineSources.lock.json`; the generated app also includes that lock and an SPDX component inventory.

| Component | Upstream license | Source |
|---|---|---|
| aria2 | GPL version 2 or later, with the upstream OpenSSL linking exception | [aria2 project](https://github.com/aria2/aria2), `COPYING`, `LICENSE.OpenSSL` in its source archive |
| OpenSSL | Apache License 2.0 | [OpenSSL project](https://github.com/openssl/openssl), `LICENSE.txt` in its source archive |
| libssh2 | BSD 3-Clause | [libssh2 project](https://github.com/libssh2/libssh2), `COPYING` in its source archive |

The app's `Contents/Resources/Licenses/` contains the applicable license texts and project notices. `EngineManifest.json` and `SBOM.spdx.json` describe bundled components. The MIT license does not relicense aria2, libssh2, their backports, or OpenSSL.

Distribution archives include a `CorrespondingSource` directory containing the exact upstream source archives, applied security patches, locked checksums, build recipe, and actual build script used for the engine. Its `BUILD.txt` explains rebuilding without installing anything globally. Keep these materials and notices with any redistribution. Packaging refuses missing or mismatched source/patch files. Local aria2 changes retain its upstream GPL terms and OpenSSL exception; libssh2 backports retain its BSD terms.

Debug builds may launch a separately installed aria2. Such an external engine is not part of the application package and has its own version and patch history.

## Apple system components

The application uses system SwiftUI, AppKit, Foundation, CryptoKit, SQLite, and other Apple SDK facilities. The source-built engine dynamically links only macOS system libraries/frameworks, including system zlib, libxml2, and SQLite. Separate copies of these system libraries are not bundled; their use remains subject to their applicable terms.

## FDM reference material

Free Download Manager was inspected locally as a behavioral reference. Its recovered code, UI resources, artwork, and binaries are not included in the source, repository, or distribution.
