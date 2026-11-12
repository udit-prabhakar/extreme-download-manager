"""Fail closed on incomplete, non-relocatable, incompatible, or unsigned app bundles."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(args):
    return subprocess.check_output([str(value) for value in args], text=True, stderr=subprocess.STDOUT)

def version(value):
    parts = [int(part) for part in value.split('.')]
    return tuple(parts + [0] * (3 - len(parts)))

def verify(app, development=False):
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    resources = app / 'Contents/Resources'
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    engine = resources / 'aria2c'
    helper = app / 'Contents/MacOS/EDMBrowserHost'
    manifest = json.loads((resources / 'EngineManifest.json').read_text())
    lock = json.loads((resources / 'EngineSources.lock.json').read_text())
    minimum = version(info['LSMinimumSystemVersion'])
    require(info['CFBundleIdentifier'] == 'app.extreme.downloadmanager', 'Wrong bundle identity')
    require(manifest['sources'] == lock['sources'], 'Engine provenance does not match the source lock')
    require(hashlib.sha256(engine.read_bytes()).hexdigest() == manifest['bundled_engine_sha256'], 'Engine bytes do not match signed bundle metadata')
    architectures = run(['lipo', '-archs', executable]).split()
    for binary in [executable, engine, helper]:
        require(run(['lipo', '-archs', binary]).split() == architectures, 'Bundled component architectures differ')
        for line in run(['otool', '-L', binary]).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            require(dependency.startswith(('/usr/lib/', '/System/Library/')), 'External runtime dependency: ' + dependency)
        commands = run(['otool', '-l', binary])
        minima = re.findall('\\bminos\\s+(\\d+(?:\\.\\d+)+)', commands)
        minima += re.findall('cmd LC_VERSION_MIN_MACOSX\\s+cmdsize \\d+\\s+version (\\d+(?:\\.\\d+)+)', commands)
        require(minima and all((version(value) <= minimum for value in minima)), 'A component requires newer macOS than the app advertises')
    require((app / 'Contents/MacOS/EDMBrowserHost').is_file(), 'Missing browser native host')
    for browser in ['chromium', 'firefox']:
        extension = resources / 'BrowserExtensions' / browser
        data = json.loads((extension / 'manifest.json').read_text())
        require(data.get('permissions') == ['nativeMessaging', 'contextMenus', 'storage', 'activeTab'], 'Unexpected browser permissions')
        for name in ['core.js', 'background.js', 'popup.html', 'popup.js', 'popup.css']:
            require((extension / name).is_file(), 'Incomplete extension')
    for component in lock['sources']:
        require(list((resources / 'Licenses' / component['name']).glob('*')), 'Missing component license')
    require((resources / 'Licenses/PROJECT-LICENSE').exists(), 'Missing project license')
    require((resources / 'Licenses/THIRD_PARTY_NOTICES.md').exists(), 'Missing third-party notices')
    build = json.loads((resources / 'BuildInfo.json').read_text())
    require((resources / 'SBOM.spdx.json').is_file(), 'Missing component inventory')
    run(['codesign', '--verify', '--deep', '--strict', app])
    signature = run(['codesign', '--display', '--verbose=4', app])
    require('runtime' in signature, 'Hardened runtime is not enabled')
    if not development:
        require('Authority=Developer ID Application:' in signature, 'Public release requires Developer ID Application signing')
        team = os.environ.get('EDM_TEAM_ID', '')
        require(re.fullmatch('[A-Z0-9]{10}', team) and ('TeamIdentifier=' + team + '\n') in signature, 'Public release requires the configured signing team (EDM_TEAM_ID)')
        require(build.get('dirty') is False and re.fullmatch('[0-9a-f]{40}', build.get('revision', '')), 'Public release requires a clean committed source tree')
        require('TeamIdentifier=not set' not in signature and 'TeamIdentifier=' in signature, 'Missing Apple signing team')
        run(['xcrun', 'stapler', 'validate', app])
        run(['spctl', '--assess', '--type', 'execute', '--verbose=2', app])
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'architectures': architectures, 'minimum_macos': info['LSMinimumSystemVersion'], 'distribution': 'development' if development else 'notarized'}
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--development', action='store_true', help='Allow ad-hoc signing; does not claim notarization')
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.app, args.development), indent=2))
    except Exception as error:
        raise SystemExit('Bundle verification failed: ' + str(error))
