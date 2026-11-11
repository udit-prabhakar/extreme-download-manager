"""Loopback-only deterministic range server; no external network dependencies."""
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time

PAYLOAD = bytes(range(256)) * (24 * 1024 * 1024 // 256)
REQUESTS = []
PHASE = 0

def bencode(value):
    if isinstance(value, int): return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes): return str(len(value)).encode() + b':' + value
    if isinstance(value, dict): return b'd' + b''.join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(value)

TORRENT = bencode({b'info': {b'length': len(PAYLOAD), b'name': b'fixture.bin', b'piece length': 1024 * 1024,
                          b'pieces': b''.join(hashlib.sha1(PAYLOAD[i:i+1024*1024]).digest() for i in range(0, len(PAYLOAD), 1024*1024))}})

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_HEAD(self): self.respond(False)
    def do_GET(self): self.respond(True)
    def respond(self, body):
        global PHASE
        if self.path == '/checkpoint': PHASE += 1
        if self.path == '/expected-sha256': data = hashlib.sha256(PAYLOAD).hexdigest().encode()
        elif self.path == '/checkpoint': data = b'ok'
        elif self.path == '/fixture.torrent': data = TORRENT
        elif self.path == '/requests': data = json.dumps(REQUESTS).encode()
        elif self.path == '/payload.bin': data = PAYLOAD
        else:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        start, end = 0, len(data) - 1
        requested = self.headers.get('Range')
        if requested:
            left, right = requested.removeprefix('bytes=').split('-', 1)
            start = int(left); end = min(int(right) if right else end, end)
            if start >= len(data):
                self.send_response(416); self.send_header('Content-Length', '0'); self.end_headers(); return
        REQUESTS.append({'path': self.path, 'range': requested, 'start': start, 'end': end, 'phase': PHASE})
        self.send_response(206 if requested else 200)
        self.send_header('Content-Length', str(end - start + 1)); self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Type', 'application/octet-stream')
        if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:
                for offset in range(start, end + 1, 32768):
                    self.wfile.write(data[offset:min(end + 1, offset + 32768)])
                    self.wfile.flush()
                    if self.path == '/payload.bin': time.sleep(0.003)
            except (BrokenPipeError, ConnectionResetError): pass

if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    if len(sys.argv) > 1: Path(sys.argv[1]).write_text(str(server.server_port))
    print(f'Fixture server: http://127.0.0.1:{server.server_port}', flush=True)
    server.serve_forever()
