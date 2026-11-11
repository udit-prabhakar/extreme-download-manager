#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
configuration="${1:-release}"
swift build -c "$configuration" --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
app="$PWD/build/Extreme Download Manager.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/ExtremeDownloadManager" "$app/Contents/MacOS/ExtremeDownloadManager"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp scripts/EDMBrowserHost "$app/Contents/MacOS/EDMBrowserHost"
chmod 755 "$app/Contents/MacOS/EDMBrowserHost"
python3 scripts/package_browser_extensions.py "$app/Contents/Resources/BrowserExtensions"
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/generate_icon.swift "$PWD/.build/AppIcon.iconset"
python3 scripts/iconset_to_icns.py .build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
printf '\nBuilt: %s\n' "$app"
