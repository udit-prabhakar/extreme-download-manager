"""Package a verified app with notices, corresponding engine sources, and checksums."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from verify_bundle import verify

ROOT=Path(__file__).resolve().parent.parent

def package(app, development=False):
    details=verify(app,development)
    flavor='development' if development else 'notarized'
    name=f'Extreme-Download-Manager-{details["version"]}-{details["architectures"][0]}-{flavor}'
    output=ROOT/'build/distributions'
    output.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.distribution-',dir=ROOT/'build') as temporary:
        folder=Path(temporary)/name
        folder.mkdir()
        subprocess.run(['ditto',str(app),str(folder/Path(app).name)],check=True)
        sources=folder/'CorrespondingSource'
        (sources/'archives').mkdir(parents=True)
        (sources/'scripts').mkdir()
        lock=json.loads((Path(app)/'Contents/Resources/EngineSources.lock.json').read_text())
        manifest=json.loads((Path(app)/'Contents/Resources/EngineManifest.json').read_text())
        built=json.loads((ROOT/'.build/engine/output/manifest.json').read_text())
        if manifest['fingerprint']!=built['fingerprint'] or manifest['prebundle_engine_sha256']!=built['prebundle_engine_sha256']:
            raise RuntimeError('The available engine build does not match this app; rebuild before packaging')
        for item in lock['sources']:
            archive=ROOT/'.build/engine/archives'/item['archive']
            with archive.open('rb') as stream: actual=hashlib.file_digest(stream,'sha256').hexdigest()
            if actual!=item['sha256']: raise RuntimeError('Missing or mismatched corresponding source: '+item['name'])
            shutil.copy2(archive,sources/'archives'/archive.name)
            for patch in item.get('patches', []):
                if 'local_file' in patch:
                    original=ROOT/'.build/engine/output'/patch['local_file']
                    target=sources/patch['local_file']
                else:
                    original=ROOT/'.build/engine/patches'/patch['file']
                    target=sources/'patches'/patch['file']
                if hashlib.sha256(original.read_bytes()).hexdigest()!=patch['sha256']: raise RuntimeError('Corresponding security patch mismatch')
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(original,target)
        shutil.copy2(Path(app)/'Contents/Resources/EngineSources.lock.json',sources/'EngineSources.lock.json')
        recipe=ROOT/'.build/engine/output/build_engine.py'
        if hashlib.sha256(recipe.read_bytes()).hexdigest()!=manifest['build_script_sha256']: raise RuntimeError('Engine build script provenance mismatch')
        shutil.copy2(recipe,sources/'scripts/build_engine.py')
        shutil.copy2(ROOT/'.build/engine/output/build-recipe.json',sources/'build-recipe.json')
        (sources/'BUILD.txt').write_text('Upstream source archives, security patches, and the exact engine build recipe are included.\nOn a native Mac with Apple command-line tools, Python 3.12+, and pkg-config:\n  python3 scripts/build_engine.py --archives ./archives\nAll sources and patches are SHA-256 pinned. Build output stays in .build; nothing is installed globally.\n')
        shutil.copy2(ROOT.parent/'THIRD_PARTY_NOTICES.md',folder/'THIRD_PARTY_NOTICES.md')
        shutil.copy2(ROOT.parent/'LICENSE',folder/'PROJECT-LICENSE')
        (folder/'READ-ME.txt').write_text('Extreme Download Manager\n\nDrag Extreme Download Manager.app to Applications, then open it. The transfer engine is bundled; Homebrew is not required.\n\n'+('DEVELOPMENT BUILD: locally ad-hoc signed; NOT notarized for public distribution. Do not disable macOS security protections to install it.\n' if development else 'Developer ID signed and notarized.\n')+'\nEngine sources and build instructions are in CorrespondingSource. Browser extensions require the setup described inside Browser links.\n')
        (folder/'release.json').write_text(json.dumps(details,indent=2)+'\n')
        checksum=[]
        for file in sorted(folder.rglob('*')):
            if file.is_file():
                with file.open('rb') as stream: value=hashlib.file_digest(stream,'sha256').hexdigest()
                checksum.append(value+'  '+str(file.relative_to(folder)))
        (folder/'SHA256SUMS').write_text('\n'.join(checksum)+'\n')
        archive=output/(name+'.zip')
        subprocess.run(['ditto','-c','-k','--keepParent',str(folder),str(archive)],check=True)
    with archive.open('rb') as stream: value=hashlib.file_digest(stream,'sha256').hexdigest()
    archive.with_suffix('.zip.sha256').write_text(value+'  '+archive.name+'\n')
    print(archive)
    return archive

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--development',action='store_true')
    args=parser.parse_args()
    try: package(args.app.resolve(),args.development)
    except Exception as error: raise SystemExit('Distribution refused: '+str(error))
