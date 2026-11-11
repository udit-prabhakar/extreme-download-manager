"""Native-messaging framing tests against the real Swift executable; no UI launches."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
binary = root / '.build/debug/ExtremeDownloadManager'
origin = 'chrome-extension://khfkcfjbpjhanmpplpkldiobnkkaoibj/'
profile = Path(tempfile.mkdtemp(prefix='browser-host-', dir=root / '.build'))
env = {**os.environ, 'EDM_DATA_DIR': str(profile), 'EDM_NATIVE_HOST_NO_LAUNCH': '1'}

def invoke(message=None, *, arguments=None, raw=None, ok=True):
    data = json.dumps(message).encode() if raw is None else raw
    packet = struct.pack('<I', len(data)) + data if raw is None else raw
    result = subprocess.run([str(binary), '--browser-native-host', *(arguments or [origin])], input=packet, capture_output=True, env=env, timeout=15)
    assert len(result.stdout) >= 4, result.stderr.decode()
    length = struct.unpack('<I', result.stdout[:4])[0]
    assert length == len(result.stdout)-4, 'stdout contains something other than one framed reply'
    reply = json.loads(result.stdout[4:])
    assert reply['ok'] == ok, reply
    assert result.returncode == (0 if ok else 1), reply
    return reply

assert invoke({'version':1,'action':'ping'})['reviewRequired']
assert not (profile/'BrowserInbox').exists(), 'Ping must not create captures'
request = {'version':1,'action':'handoff','url':'https://example.invalid/fixture?token=synthetic','title':'Local fixture'}
reply = invoke(request)
files = list((profile/'BrowserInbox').glob('*.json'))
assert len(files)==1
record = json.loads(files[0].read_text())
assert record['url']==request['url'] and record['id']==reply['requestID']
assert files[0].stat().st_mode & 0o777 == 0o600
assert (profile/'BrowserInbox').stat().st_mode & 0o777 == 0o700
invoke(request, arguments=['/fixture/manifest.json','browser@extreme.downloadmanager.app'])
for url in ['file:///tmp/hello', 'javascript:alert(1)', 'https://user:password@example.invalid/file', 'magnet:?dn=hello', 'https://example.invalid/a\nheader']:
    invoke({**request,'url':url}, ok=False)
invoke(request, arguments=['chrome-extension://untrusted/'], ok=False)
invoke({'version':2,'action':'handoff','url':request['url']}, ok=False)
invoke(raw=struct.pack('<I',20000), ok=False)
invoke(raw=struct.pack('<I',10)+b'{}', ok=False)
invoke(raw=struct.pack('<I',3)+b'bad', ok=False)
assert len(list((profile/'BrowserInbox').glob('*.json')))==2, 'Rejected input created a capture'
print('PASS: native host framing, extension allowlist, permissions, URL validation, and Chrome/Firefox arguments')
print(f'Evidence: {profile}')
