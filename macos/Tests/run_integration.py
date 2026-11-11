from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parent.parent
run = Path(tempfile.mkdtemp(prefix='integration-', dir=root / '.build'))
port_file = run / 'port'
server = subprocess.Popen([sys.executable, str(root / 'Tests/fixture_server.py'), str(port_file)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    for _ in range(100):
        if port_file.exists(): break
        if server.poll() is not None: raise RuntimeError(server.stderr.read().decode())
        time.sleep(.05)
    port = int(port_file.read_text())
    base = f'http://127.0.0.1:{port}'
    env = {**os.environ, 'EDM_DATA_DIR': str(run / 'app-data'), 'EDM_OFFLINE_TEST': '1'}
    result = subprocess.run([str(root / '.build/debug/ExtremeDownloadManager'), '--engine-self-test', '--test-url', base], env=env, text=True, capture_output=True, timeout=300)
    print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
    (run / 'swift-test.log').write_text(result.stdout + result.stderr)
    if result.returncode: sys.exit(result.returncode)
    requests = json.load(urllib.request.urlopen(base + '/requests'))
    ranges = [item for item in requests if item['path'] == '/payload.bin' and item['range']]
    assert len(ranges) >= 2, f'Expected multiple range requests, got {ranges}'
    assert any(item['start'] > 0 for item in ranges), 'No nonzero range requested'
    resumed = [item for item in ranges if item['phase'] == 1]
    assert resumed and all(item['start'] > 0 for item in resumed), 'Resumed transfer restarted at byte zero'
    (run / 'http-requests.json').write_text(json.dumps(requests, indent=2))
    print(f'PASS: server recorded {len(ranges)} Range requests, including nonzero offsets')
    print('PASS: after restart, all payload requests resume at nonzero byte offsets')
    print(f'Evidence: {run}')
finally:
    server.terminate()
    try: server.wait(timeout=5)
    except subprocess.TimeoutExpired: server.kill(); server.wait()
