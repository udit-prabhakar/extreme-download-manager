"""Exercise the relocated release bundle without a Homebrew runtime or GUI launch."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from fixture_server import Handler, PAYLOAD, bencode

ROOT=Path(__file__).resolve().parent.parent
app=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT/'build/Extreme Download Manager.app'
evidence=Path(tempfile.mkdtemp(prefix='package-smoke-',dir=ROOT/'.build'))
moved=evidence/'Relocated directory'/'Moved Download Manager.app'
shutil.copytree(app,moved)
engine=moved/'Contents/Resources/aria2c'
executable=moved/'Contents/MacOS/ExtremeDownloadManager'
env={key:value for key,value in os.environ.items() if key not in ('EDM_ARIA2_PATH','DYLD_LIBRARY_PATH','DYLD_FALLBACK_LIBRARY_PATH','SSL_CERT_FILE','SSL_CERT_DIR')}
env.update({'PATH':'/usr/bin:/bin','EDM_DATA_DIR':str(evidence/'profile'),'EDM_NATIVE_HOST_NO_LAUNCH':'1','EDM_OFFLINE_TEST':'1'})

def run(args, *, expected=0, data=None, environment=None):
    result=subprocess.run([str(arg) for arg in args],input=data,capture_output=True,env=environment or env,timeout=90)
    if expected is not None and result.returncode!=expected:
        raise RuntimeError(result.stderr.decode(errors='replace')+'\n'+result.stdout.decode(errors='replace'))
    return result

run([sys.executable,ROOT/'scripts/verify_bundle.py',moved,'--development'])
result=run([sys.executable,ROOT/'scripts/verify_bundle.py',moved],expected=None)
signature=run(['codesign','--display','--verbose=4',moved]).stderr
if b'Signature=adhoc' in signature:
    assert result.returncode!=0 and b'Developer ID' in result.stderr+result.stdout, 'Ad-hoc build was accepted as a public release'
run([executable,'--engine-self-test'],expected=64)
version=run([engine,'--no-conf=true','--version']).stdout.decode()
assert 'HTTPS' in version and 'SFTP' in version and 'BitTorrent' in version
packet=json.dumps({'version':1,'action':'ping'}).encode()
reply=run([moved/'Contents/MacOS/EDMBrowserHost','chrome-extension://khfkcfjbpjhanmpplpkldiobnkkaoibj/'],data=struct.pack('<I',len(packet))+packet).stdout
assert struct.unpack('<I',reply[:4])[0]==len(reply)-4 and json.loads(reply[4:])['ok']
print('PASS: relocated app/engine/helper work with system-only PATH; release omits debug self-tests; ad-hoc builds are checked for public-release refusal')

original=engine.read_bytes()
try:
    engine.write_bytes(original+b'fixture tamper')
    result=run([sys.executable,ROOT/'scripts/verify_bundle.py',moved,'--development'],expected=None,environment={**env,'PYTHONOPTIMIZE':'1'})
    assert result.returncode!=0 and b'Engine bytes' in result.stderr+result.stdout, 'Tampered engine bypassed the optimized release gate'
finally: engine.write_bytes(original)
print('PASS: engine tampering is rejected even with Python optimization enabled')

cert=evidence/'fixture-cert.pem'
key=evidence/'fixture-key.pem'
configuration=evidence/'fixture-openssl.cnf'
configuration.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=EDM Local Fixture Root CA\n[extensions]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n')
run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',key,'-out',cert,'-config',configuration])
key.chmod(0o600)
leaf_key=evidence/'leaf-key.pem'
request=evidence/'leaf.csr'
run(['/usr/bin/openssl','req','-new','-newkey','rsa:2048','-nodes','-keyout',leaf_key,'-out',request,'-subj','/CN=localhost'])
leaf_key.chmod(0o600)
def leaf(name, purpose, names='IP:127.0.0.1,DNS:localhost'):
    extension=evidence/(name+'.cnf')
    extension.write_text('subjectAltName='+names+'\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage='+purpose+'\n')
    result=evidence/(name+'.pem')
    run(['/usr/bin/openssl','x509','-req','-in',request,'-CA',cert,'-CAkey',key,'-CAserial',evidence/'fixture-ca.srl','-CAcreateserial','-days','1','-extfile',extension,'-out',result])
    return result
valid=leaf('server','serverAuth')
wrong_purpose=leaf('client-only','clientAuth')
wrong_name=leaf('wrong-name','serverAuth','DNS:other.invalid')
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(valid,leaf_key)
server.socket=context.wrap_socket(server.socket,server_side=True)
thread=threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
try:
    url=f'https://127.0.0.1:{server.server_port}/payload.bin'
    options=[engine,'--no-conf=true','--check-certificate=true','--max-tries=1','--connect-timeout=5','--timeout=15','--console-log-level=error','--summary-interval=0','--download-result=hide','--dir='+str(evidence)]
    rejected=run([*options,'--out=untrusted.bin',url],expected=None)
    assert rejected.returncode!=0, 'Untrusted TLS certificate was accepted'
    run([*options,'--ca-certificate='+str(cert),'--out=trusted.bin',url])
    assert hashlib.sha256((evidence/'trusted.bin').read_bytes()).digest()==hashlib.sha256(PAYLOAD).digest(), 'HTTPS output hash mismatch'
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=5)
print('PASS: bundled engine rejects an untrusted TLS certificate and downloads correct bytes with an explicitly trusted local fixture CA')
for name,certificate in [('wrong-purpose',wrong_purpose),('wrong-hostname',wrong_name)]:
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate,leaf_key)
    server.socket=context.wrap_socket(server.socket,server_side=True)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        result=run([*options,'--ca-certificate='+str(cert),'--out='+name+'.bin',f'https://127.0.0.1:{server.server_port}/payload.bin'],expected=None)
        assert result.returncode>0, name+' certificate was accepted or caused a crash'
    finally:
        server.shutdown();server.server_close();thread.join(timeout=5)
invalid=evidence/'zero-piece.torrent'
invalid.write_bytes(bencode({b'info':{b'length':1,b'name':b'fixture.bin',b'piece length':0,b'pieces':b'x'*20}}))
result=run([engine,'--no-conf=true','--show-files=true',invalid],expected=None)
# aria2's show-files command reports parse errors in output while returning zero.
assert result.returncode>=0 and b'errorCode=26' in result.stdout+result.stderr, 'Zero-length torrent piece caused a signal or was not rejected as invalid metadata'
nul=evidence/'nul-input.txt';nul.write_bytes(b'\0\n')
result=run([engine,'--no-conf=true','--input-file='+str(nul),'--console-log-level=error'],expected=None)
assert result.returncode>=0, 'NUL text input caused a signal'
print('PASS: trusted but wrong-purpose/wrong-hostname certificates are rejected; malformed torrent/text fixtures fail without signals')
print('Evidence: '+str(evidence))
