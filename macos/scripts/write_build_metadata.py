"""Create a source revision record and SPDX component inventory before bundle signing."""
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import uuid

app=Path(sys.argv[1])
resources=app/'Contents/Resources'
root=Path(__file__).resolve().parent.parent.parent
created=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip())
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
(resources/'BuildInfo.json').write_text(json.dumps({'revision':revision,'dirty':dirty,'created':created,'architecture':platform.machine()},indent=2)+'\n')
if (resources/'EngineSources.lock.json').exists():
    lock=json.loads((resources/'EngineSources.lock.json').read_text())
    packages=[{'SPDXID':'SPDXRef-Application','name':'Extreme Download Manager','versionInfo':info['CFBundleShortVersionString'],'downloadLocation':'https://github.com/udit-prabhakar/extreme-download-manager','filesAnalyzed':False,'licenseConcluded':'NOASSERTION','licenseDeclared':'MIT','copyrightText':'NOASSERTION'}]
    for component in lock['sources']:
        packages.append({'SPDXID':'SPDXRef-'+component['name'],'name':component['name'],'versionInfo':component['version'],'downloadLocation':component['url'],'filesAnalyzed':False,'licenseConcluded':'NOASSERTION','licenseDeclared':component['license'],'copyrightText':'NOASSERTION','checksums':[{'algorithm':'SHA256','checksumValue':component['sha256']}]})
        advisory_ids=sorted({identifier for patch in component.get('patches',[]) for identifier in patch.get('advisories',[])})
        if advisory_ids:
            packages[-1]['annotations']=[{'annotationType':'OTHER','annotator':'Tool: EDM-release-tooling','annotationDate':created,'comment':'Security backports applied; see EngineSources.lock.json and corresponding source patches: '+', '.join(advisory_ids)}]
    document={'spdxVersion':'SPDX-2.3','dataLicense':'CC0-1.0','SPDXID':'SPDXRef-DOCUMENT','name':'Extreme Download Manager component inventory','documentNamespace':'https://github.com/udit-prabhakar/extreme-download-manager/spdx/'+str(uuid.uuid4()),'creationInfo':{'created':created,'creators':['Tool: EDM-release-tooling']},'packages':packages,'relationships':[{'spdxElementId':'SPDXRef-DOCUMENT','relationshipType':'DESCRIBES','relatedSpdxElement':'SPDXRef-Application'},{'spdxElementId':'SPDXRef-Application','relationshipType':'CONTAINS','relatedSpdxElement':'SPDXRef-aria2'},{'spdxElementId':'SPDXRef-aria2','relationshipType':'STATIC_LINK','relatedSpdxElement':'SPDXRef-openssl'},{'spdxElementId':'SPDXRef-aria2','relationshipType':'STATIC_LINK','relatedSpdxElement':'SPDXRef-libssh2'}]}
    (resources/'SBOM.spdx.json').write_text(json.dumps(document,indent=2)+'\n')
