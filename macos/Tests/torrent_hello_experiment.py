"""Local-only BitTorrent v1 experiment using a real aria2 receiving client.

The generated torrent has one piece and a loopback tracker. DHT, PEX, and
local-peer discovery are disabled. No public torrent or peer is contacted.
"""
from pathlib import Path
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = Path(tempfile.mkdtemp(prefix='torrent-hello-', dir=ROOT / '.build'))
ORIGINAL = (b'EDM local torrent test. ' * 1000)[:16384]
MODIFIED = b'hello' + ORIGINAL[5:]

def bencode(value):
    if isinstance(value, int): return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes): return str(len(value)).encode() + b':' + value
    if isinstance(value, dict):
        return b'd' + b''.join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(type(value))

INFO = {b'length': len(ORIGINAL), b'name': b'hello-experiment.bin',
        b'piece length': 16384, b'pieces': hashlib.sha1(ORIGINAL).digest()}
INFO_HASH = hashlib.sha1(bencode(INFO)).digest()

def read_exact(connection, size):
    data = b''
    while len(data) < size:
        block = connection.recv(size - len(data))
        if not block: raise EOFError('Peer disconnected')
        data += block
    return data

class LocalSeeder:
    def __init__(self, content):
        self.content = content
        self.sent = []
        self.stopping = threading.Event()
        self.socket = socket.socket()
        self.socket.bind(('127.0.0.1', 0))
        self.port = self.socket.getsockname()[1]
        self.socket.listen()
        self.socket.settimeout(.2)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopping.is_set():
            try: connection, address = self.socket.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=self.peer, args=(connection,), daemon=True).start()

    def peer(self, connection):
        with connection:
            connection.settimeout(3)
            try:
                handshake = read_exact(connection, 68)
                assert handshake[:20] == b'\x13BitTorrent protocol'
                assert handshake[28:48] == INFO_HASH
                peer_id = b'-EDM001-localtestpeer'[:20]
                connection.sendall(b'\x13BitTorrent protocol' + b'\0' * 8 + INFO_HASH + peer_id)
                connection.sendall(struct.pack('>I', 2) + b'\x05\x80')  # bitfield: one available piece
                connection.sendall(struct.pack('>I', 1) + b'\x01')  # unchoke
                while not self.stopping.is_set():
                    length = struct.unpack('>I', read_exact(connection, 4))[0]
                    if length == 0: continue
                    assert length <= 65536
                    message = read_exact(connection, length)
                    if message[0] != 6: continue
                    index, begin, requested = struct.unpack('>III', message[1:])
                    assert index == 0 and 0 < requested <= 16384
                    block = self.content[begin:begin + requested]
                    response = b'\x07' + struct.pack('>II', index, begin) + block
                    connection.sendall(struct.pack('>I', len(response)) + response)
                    self.sent.append({'index': index, 'begin': begin, 'length': len(block), 'contains_hello': b'hello' in block})
            except (EOFError, OSError, AssertionError, struct.error): pass

    def close(self):
        self.stopping.set()
        self.socket.close()
        self.thread.join(timeout=2)

def transfer(label, content):
    folder = OUTPUT / label
    folder.mkdir()
    seeder = LocalSeeder(content)

    class Tracker(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            # This tracker advertises exactly one loopback peer.
            answer = bencode({b'interval': 1, b'complete': 1, b'incomplete': 0,
                              b'peers': socket.inet_aton('127.0.0.1') + struct.pack('>H', seeder.port)})
            self.send_response(200)
            self.send_header('Content-Length', str(len(answer)))
            self.end_headers()
            self.wfile.write(answer)

    tracker = ThreadingHTTPServer(('127.0.0.1', 0), Tracker)
    tracker_thread = threading.Thread(target=tracker.serve_forever, daemon=True)
    tracker_thread.start()
    torrent = {b'announce': f'http://127.0.0.1:{tracker.server_port}/announce'.encode(), b'info': INFO}
    torrent_path = folder / 'local.torrent'
    torrent_path.write_bytes(bencode(torrent))
    logfile = folder / 'aria2.log'
    executable = shutil.which('aria2c')
    assert executable, 'aria2c is required'
    command = [executable, '--no-conf', '--enable-dht=false', '--enable-dht6=false',
               '--enable-peer-exchange=false', '--bt-enable-lpd=false', '--no-netrc=true',
               '--seed-time=0', '--bt-stop-timeout=3', '--bt-max-peers=1',
               '--max-tries=1', '--summary-interval=0', '--console-log-level=error',
               '--file-allocation=none', '--log-level=debug', f'--log={logfile}',
               f'--dir={folder}', str(torrent_path)]
    try:
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=18,
                                    env={'PATH': '/usr/bin:/bin:/opt/homebrew/bin', 'HOME': str(folder)})
            code, output = result.returncode, result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            code, output = -1, 'Test deadline reached; owned aria2 child stopped.'
        (folder / 'console.txt').write_text(output)
        log = logfile.read_text(errors='replace') if logfile.exists() else ''
        destination = folder / 'hello-experiment.bin'
        correct_file = destination.exists() and hashlib.sha1(destination.read_bytes()).digest() == INFO[b'pieces']
        evidence = [line.strip() for line in log.splitlines() if any(needle in line.lower() for needle in ['hash check failed', 'hash mismatch', 'wrong piece', 'checksum error', 'piece hash'])]
        return {'exit_code': code, 'sent_blocks': seeder.sent, 'valid_file': correct_file, 'integrity_log': evidence[:20]}
    finally:
        tracker.shutdown(); tracker.server_close(); tracker_thread.join(timeout=2); seeder.close()

if __name__ == '__main__':
    original = transfer('original', ORIGINAL)
    modified = transfer('modified-with-hello', MODIFIED)
    assert original['valid_file'] and original['sent_blocks'], original
    assert any(block['contains_hello'] for block in modified['sent_blocks']), modified
    assert not modified['valid_file'], modified
    # Top-level comments are outside info and do not change the swarm identity.
    plain = {b'info': INFO}
    commented = {b'comment': b'hello', b'info': INFO}
    (OUTPUT / 'plain.torrent').write_bytes(bencode(plain))
    (OUTPUT / 'hello-comment.torrent').write_bytes(bencode(commented))
    info_with_hello = {**INFO, b'comment': b'hello'}
    result = {
        'original_piece': original,
        'hello_in_piece': modified,
        'expected_piece_sha1': INFO[b'pieces'].hex(),
        'modified_piece_sha1': hashlib.sha1(MODIFIED).hexdigest(),
        'original_info_hash': INFO_HASH.hex(),
        'top_level_comment_info_hash': hashlib.sha1(bencode(commented[b'info'])).hexdigest(),
        'hello_inside_info_hash': hashlib.sha1(bencode(info_with_hello)).hexdigest(),
        'metadata_note': 'BEP 9 transfers only the info dictionary; a top-level comment is not sent by that extension.',
    }
    (OUTPUT / 'results.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    print(f'Evidence: {OUTPUT}')
