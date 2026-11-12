#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: build.sh [debug|release]' >&2; exit 64;; esac
swift build -c "$configuration" --scratch-path .build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
mkdir -p build
stage="$(mktemp -d "$PWD/build/.staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Extreme Download Manager.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp ".build/$configuration/ExtremeDownloadManager" "$app/Contents/MacOS/ExtremeDownloadManager"
cp Resources/Info.plist "$app/Contents/Info.plist"
xcrun clang -Os -Wall -Wextra -mmacosx-version-min=13.0 scripts/browser_host.c -o "$app/Contents/MacOS/EDMBrowserHost"
python3 scripts/package_browser_extensions.py "$app/Contents/Resources/BrowserExtensions"
cp ../LICENSE "$app/Contents/Resources/Licenses/PROJECT-LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
identity="${EDM_SIGNING_IDENTITY:--}"
sign_args=(--force --options runtime --sign "$identity")
if [[ "$identity" != '-' ]]; then sign_args+=(--timestamp); fi
codesign "${sign_args[@]}" "$app/Contents/MacOS/EDMBrowserHost"
if [[ "$configuration" == 'release' ]]; then
  python3 scripts/build_engine.py
  cp .build/engine/output/aria2c "$app/Contents/Resources/aria2c"
  cp .build/engine/output/EngineSources.lock.json "$app/Contents/Resources/EngineSources.lock.json"
  cp -R .build/engine/output/Licenses/. "$app/Contents/Resources/Licenses/"
  codesign "${sign_args[@]}" "$app/Contents/Resources/aria2c"
  python3 - "$app" <<'PY'
import hashlib,json,sys
from pathlib import Path
resources=Path(sys.argv[1])/'Contents/Resources'
manifest=json.loads(Path('.build/engine/output/manifest.json').read_text())
manifest['bundled_engine_sha256']=hashlib.sha256((resources/'aria2c').read_bytes()).hexdigest()
(resources/'EngineManifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
fi
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/generate_icon.swift "$PWD/.build/AppIcon.iconset"
python3 scripts/iconset_to_icns.py .build/AppIcon.iconset "$app/Contents/Resources/AppIcon.icns"
python3 scripts/write_build_metadata.py "$app"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$configuration" == 'release' ]]; then python3 scripts/verify_bundle.py "$app" --development; fi
python3 - "$app" "$PWD/build/Extreme Download Manager.app" <<'PY'
from pathlib import Path
import os,shutil,sys
source,target=map(Path,sys.argv[1:])
previous=source.parent/'previous.app'
if target.exists(): os.replace(target,previous)
try: os.replace(source,target)
except BaseException:
    if previous.exists(): os.replace(previous,target)
    raise
if previous.exists(): shutil.rmtree(previous)
PY
printf '\nBuilt: %s\n' "$PWD/build/Extreme Download Manager.app"
