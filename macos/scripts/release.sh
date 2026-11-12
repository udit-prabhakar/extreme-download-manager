#!/bin/bash
# Public release path: credentials stay in Keychain; never pass passwords here.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${EDM_SIGNING_IDENTITY:-}" != 'Developer ID Application:'* || -z "${EDM_NOTARY_PROFILE:-}" || -z "${EDM_TEAM_ID:-}" ]]; then
  echo 'Public release requires EDM_SIGNING_IDENTITY (Developer ID Application), EDM_TEAM_ID, and EDM_NOTARY_PROFILE (an existing notarytool Keychain profile).' >&2
  exit 78
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Public release requires a clean committed source tree.' >&2
  exit 65
fi
bash scripts/build.sh release
app="$PWD/build/Extreme Download Manager.app"
python3 - "$app" <<'PY'
import os,re,subprocess,sys
team=os.environ['EDM_TEAM_ID']
signature=subprocess.check_output(['codesign','--display','--verbose=4',sys.argv[1]],stderr=subprocess.STDOUT,text=True)
if not re.fullmatch('[A-Z0-9]{10}',team) or 'TeamIdentifier='+team+'\n' not in signature:
    raise SystemExit('Signing identity does not match EDM_TEAM_ID; no submission was made.')
PY
EDM_ARIA2_PATH="$app/Contents/Resources/aria2c" bash scripts/test.sh
python3 Tests/test_packaged_app.py "$app"
submission="$PWD/build/notary-submission.zip"
ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$EDM_NOTARY_PROFILE" --wait --timeout 20m --output-format json > build/notary-result.json
python3 - <<'PY'
import json
result=json.load(open('build/notary-result.json'))
if result.get('status')!='Accepted': raise SystemExit('Notarization was not accepted. Review build/notary-result.json; no public distribution was created.')
PY
xcrun stapler staple "$app"
python3 scripts/verify_bundle.py "$app"
python3 scripts/package_distribution.py "$app"
