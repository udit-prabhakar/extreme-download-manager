"""Build a pinned native aria2 with static non-system dependencies. Never install globally."""
import hashlib
import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'EngineSources.lock.json'
WORK = ROOT / '.build/engine'
OUTPUT = WORK / 'output'
RECIPE = Path(__file__).read_bytes()

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def build():
    if sys.version_info < (3, 12):
        raise RuntimeError('Engine source builds require Python 3.12+ for safe archive extraction.')
    if sys.platform != 'darwin' or platform.machine() not in ('arm64', 'x86_64'):
        raise RuntimeError('Build natively on an Apple Silicon or Intel Mac.')
    if any(char.isspace() for char in str(WORK)):
        raise RuntimeError('The native source build needs a checkout path without whitespace.')
    lock = json.loads(LOCK.read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archives', type=Path, default=WORK/'archives', help='Directory containing the pinned source archives; missing archives are downloaded and verified')
    archives = parser.parse_args().archives.resolve()
    patches = archives.parent/'patches'
    patches.mkdir(parents=True, exist_ok=True)
    inputs = []
    for item in lock['sources']:
        for patch in item.get('patches', []):
            file = ROOT/patch['local_file'] if 'local_file' in patch else patches/patch['file']
            if 'url' in patch and (not file.exists() or digest(file) != patch['sha256']):
                print('Downloading pinned security backport '+patch['file'], flush=True)
                temporary = file.with_suffix('.partial')
                with urllib.request.urlopen(patch['url'], timeout=90) as response, temporary.open('wb') as target:
                    shutil.copyfileobj(response, target)
                if digest(temporary) != patch['sha256']: temporary.unlink(); raise RuntimeError('Security patch checksum mismatch')
                temporary.replace(file)
            if not file.exists() or digest(file) != patch['sha256']: raise RuntimeError('Missing or modified security patch: '+str(file))
            inputs.append((item['name']+'-'+item['version'], file))
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun', 'clang', '--version'], text=True)
    fingerprint = hashlib.sha256(LOCK.read_bytes() + RECIPE + (platform.machine() + sdk + compiler).encode()).hexdigest()
    manifest = OUTPUT / 'manifest.json'
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        if saved.get('fingerprint') == fingerprint and (OUTPUT/'aria2c').exists() and digest(OUTPUT/'aria2c') == saved['prebundle_engine_sha256'] and (OUTPUT/'build_engine.py').exists() and digest(OUTPUT/'build_engine.py') == saved['build_script_sha256'] and all((archives/item['archive']).exists() and digest(archives/item['archive']) == item['sha256'] for item in lock['sources']):
            print(f'Using verified cached engine: {OUTPUT}', flush=True)
            return
    archives.mkdir(parents=True, exist_ok=True)
    for item in lock['sources']:
        archive = archives / item['archive']
        if not archive.exists() or digest(archive) != item['sha256']:
            temporary = archive.with_suffix(archive.suffix + '.partial')
            print(f'Downloading pinned {item["name"]} {item["version"]}', flush=True)
            with urllib.request.urlopen(item['url'], timeout=90) as response, temporary.open('wb') as target:
                shutil.copyfileobj(response, target)
            if digest(temporary) != item['sha256']:
                temporary.unlink()
                raise RuntimeError(f'Source checksum mismatch for {item["name"]}')
            temporary.replace(archive)
    source = WORK / 'src'
    prefix = WORK / 'prefix'
    for directory in (source, prefix, OUTPUT):
        if directory.exists(): shutil.rmtree(directory)
        directory.mkdir(parents=True)
    for item in lock['sources']:
        with tarfile.open(archives/item['archive']) as archive:
            archive.extractall(source, filter='data')
    minimum = lock['minimum_macos']
    pkgconfig = shutil.which('pkg-config')
    if not pkgconfig: raise RuntimeError('Install pkg-config for source builds (it is not a runtime dependency).')
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'SDKROOT': sdk,
           'MACOSX_DEPLOYMENT_TARGET': minimum, 'CC': subprocess.check_output(['xcrun','--find','clang'],text=True).strip(),
           'CXX': subprocess.check_output(['xcrun','--find','clang++'],text=True).strip(),
           'CFLAGS': f'-O2 -mmacosx-version-min={minimum}', 'CXXFLAGS': f'-O2 -mmacosx-version-min={minimum}',
           'CPPFLAGS': f'-I{prefix}/include', 'LDFLAGS': f'-L{prefix}/lib -mmacosx-version-min={minimum}',
           'PKG_CONFIG': pkgconfig, 'PKG_CONFIG_LIBDIR': str(prefix/'lib/pkgconfig')}
    commands = []
    jobs = str(min(8, os.cpu_count() or 2))
    def run(component, args):
        commands.append({'component': component, 'arguments': [arg.replace(str(prefix), '${PREFIX}').replace(str(WORK), '${WORK}').replace(str(ROOT), '${SOURCE_ROOT}').replace(sdk, '${SDKROOT}') for arg in args]})
        print(component + ': ' + args[0] + (' ' + args[1] if len(args)>1 else ''), flush=True)
        with (WORK/(component+'.log')).open('a') as log:
            result = subprocess.run(args, cwd=source/component, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print('\n'.join((WORK/(component+'.log')).read_text(errors='replace').splitlines()[-35:]), file=sys.stderr)
            raise RuntimeError(f'{component} failed; see {WORK/(component+".log")}')
    for component, patch in inputs:
        run(component, ['/usr/bin/patch', '-p1', '-F0', '-t', '-N', '-i', str(patch)])
    openssl = 'openssl-' + lock['sources'][0]['version']
    target = 'darwin64-arm64-cc' if platform.machine() == 'arm64' else 'darwin64-x86_64-cc'
    run(openssl, ['perl', './Configure', target, 'no-shared', 'no-module', 'no-tests', 'no-autoload-config', '--prefix='+str(prefix), '--libdir=lib', '--openssldir=/etc/ssl'])
    run(openssl, ['make', '-j'+jobs])
    run(openssl, ['make', 'install_sw'])
    ssh = 'libssh2-' + lock['sources'][1]['version']
    run(ssh, ['./configure', '--prefix='+str(prefix), '--disable-shared', '--enable-static', '--with-crypto=openssl', '--with-libssl-prefix='+str(prefix), '--disable-examples-build', '--disable-tests'])
    run(ssh, ['make', '-j'+jobs]); run(ssh, ['make', 'install'])
    aria = 'aria2-' + lock['sources'][2]['version']
    env.update({'OPENSSL_CFLAGS': '-I'+str(prefix/'include'), 'OPENSSL_LIBS': f'{prefix}/lib/libssl.a {prefix}/lib/libcrypto.a',
                'LIBSSH2_CFLAGS': '-I'+str(prefix/'include'), 'LIBSSH2_LIBS': f'{prefix}/lib/libssh2.a {prefix}/lib/libssl.a {prefix}/lib/libcrypto.a',
                'LIBXML2_CFLAGS': '-I'+sdk+'/usr/include/libxml2', 'LIBXML2_LIBS': '-lxml2', 'SQLITE3_CFLAGS': '-I'+sdk+'/usr/include', 'SQLITE3_LIBS': '-lsqlite3'})
    env['LDFLAGS'] += ' -framework Security -framework CoreFoundation'
    run(aria, ['./configure', '--prefix='+str(prefix), '--disable-shared', '--enable-static', '--disable-nls', '--without-gnutls', '--without-libnettle', '--without-libgmp', '--without-libgcrypt', '--without-appletls', '--with-openssl', '--with-libssh2', '--without-libcares', '--with-libxml2', '--with-sqlite3', '--with-ca-bundle=/etc/ssl/cert.pem'])
    run(aria, ['make', '-j'+jobs])
    shutil.copy2(source/aria/'src/aria2c', OUTPUT/'aria2c')
    subprocess.run(['strip', '-x', str(OUTPUT/'aria2c')], check=True)
    version = subprocess.check_output([str(OUTPUT/'aria2c'), '--version'], text=True)
    for feature in ('HTTPS', 'SFTP', 'BitTorrent', 'XML-RPC'):
        if feature not in version: raise RuntimeError('Built engine is missing '+feature)
    linkage = subprocess.check_output(['otool', '-L', str(OUTPUT/'aria2c')], text=True)
    for line in linkage.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/')): raise RuntimeError('Non-system runtime dependency: '+dependency)
    for item in lock['sources']:
        folder = OUTPUT/'Licenses'/item['name']; folder.mkdir(parents=True)
        for name in item['notice_files']:
            candidate = source/(item['name']+'-'+item['version'])/name
            if candidate.exists(): shutil.copy2(candidate, folder/name)
        if not list(folder.iterdir()): raise RuntimeError('Missing license for '+item['name'])
    shutil.copy2(LOCK, OUTPUT/'EngineSources.lock.json')
    (OUTPUT/'build_engine.py').write_bytes(RECIPE)
    for item in lock['sources']:
        for patch in item.get('patches', []):
            if 'local_file' in patch:
                destination = OUTPUT/patch['local_file']
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT/patch['local_file'], destination)
    (OUTPUT/'build-recipe.json').write_text(json.dumps(commands, indent=2)+'\n')
    manifest.write_text(json.dumps({'fingerprint': fingerprint, 'architecture': platform.machine(), 'minimum_macos': minimum,
                                   'prebundle_engine_sha256': digest(OUTPUT/'aria2c'), 'build_script_sha256': hashlib.sha256(RECIPE).hexdigest(), 'version_output': version,
                                   'sources': lock['sources']}, indent=2)+'\n')
    print('Built relocatable engine with system-only dynamic linkage: '+str(OUTPUT), flush=True)

def main():
    WORK.mkdir(parents=True, exist_ok=True)
    with (WORK/'build.lock').open('a') as lock:
        print('Acquiring exclusive engine build lock…', flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        build()

if __name__ == '__main__':
    try: main()
    except Exception as error: raise SystemExit(str(error))
