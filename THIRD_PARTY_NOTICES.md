# Third-party notices

## aria2

The application launches a separately installed `aria2c` executable. aria2 is licensed under GPL version 2 or, at your option, a later version. It is not included in this repository or the current application bundle. The project's MIT license does not relicense aria2.

- Project and source: https://github.com/aria2/aria2
- License: https://github.com/aria2/aria2/blob/master/COPYING
- Manual: https://aria2.github.io/manual/en/html/aria2c.html

If a future distribution bundles aria2 or other tools, its release process must include those programs' applicable license notices and source-distribution obligations. Record new dependencies and bundled components here.

## Apple frameworks and development tools

The macOS implementation uses system SwiftUI, AppKit, Foundation, CryptoKit, and other Apple system facilities through the installed SDK. Their use and distribution remain subject to Apple's applicable terms.

The application also links the macOS system SQLite library through a small C module declaration. No separate SQLite binary or implementation source is bundled by this project.

## FDM reference material

Free Download Manager was inspected locally as a behavioral reference. Its recovered code, UI resources, artwork, and binaries are not included in the application source, repository, or release artifact.
