"""Loopback-only deterministic range server; no external network dependencies."""
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time
import socket
import struct
import urllib.parse

PAYLOAD = bytes(range(256)) * (24 * 1024 * 1024 // 256)
REQUESTS = []
PHASE = 0

def bencode(value):
    if isinstance(value, int): return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes): return str(len(value)).encode() + b':' + value
    if isinstance(value, list): return b'l' + b''.join(bencode(item) for item in value) + b'e'
    if isinstance(value, dict): return b'd' + b''.join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b'e'
    raise TypeError(value)

INFO = {b'length': len(PAYLOAD), b'name': b'fixture.bin', b'piece length': 1024 * 1024,
        b'pieces': b''.join(hashlib.sha1(PAYLOAD[i:i+1024*1024]).digest() for i in range(0, len(PAYLOAD), 1024*1024))}
TORRENT = bencode({b'info': INFO})
MULTI = bencode({b'info': {b'name': b'selected-files', b'piece length': 1024*1024,
                         b'files': [{b'length': 1024*1024, b'path': [b'keep.bin']}, {b'length': 1024*1024, b'path': [b'skip.bin']}],
                         b'pieces': hashlib.sha1(PAYLOAD[:1024*1024]).digest() * 2}})

def receive_from_engine(port):
    def exact(connection, count):
        result = b''
        while len(result) < count:
            part = connection.recv(count-len(result))
            if not part: raise EOFError('Seeder disconnected')
            result += part
        return result
    with socket.create_connection(('127.0.0.1', port), timeout=40) as peer:
        info_hash = hashlib.sha1(bencode(INFO)).digest()
        peer.sendall(b'\x13BitTorrent protocol' + bytes(8) + info_hash + b'-EDMTEST-localpeer001'[:20])
        response = exact(peer, 68)
        assert response[28:48] == info_hash
        peer.sendall(struct.pack('>I', 4) + b'\x05' + bytes(3))
        peer.sendall(struct.pack('>I', 1) + b'\x02')
        while True:
            length = struct.unpack('>I', exact(peer, 4))[0]
            if length and exact(peer, length)[0] == 1: break
        begin = time.monotonic()
        received = bytearray()
        for offset in range(0, 512*1024, 16384):
            peer.sendall(struct.pack('>I', 13) + b'\x06' + struct.pack('>III', 0, offset, 16384))
            while True:
                length = struct.unpack('>I', exact(peer, 4))[0]
                if not length: continue
                message = exact(peer, length)
                if message[0] == 7:
                    index, actual_offset = struct.unpack('>II', message[1:9])
                    assert index == 0 and actual_offset == offset
                    received.extend(message[9:]); break
        elapsed = time.monotonic() - begin
        assert bytes(received) == PAYLOAD[:512*1024]
        return {'bytes': len(received), 'seconds': elapsed, 'bytes_per_second': len(received)/elapsed}

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_HEAD(self): self.respond(False)
    def do_GET(self): self.respond(True)
    def respond(self, body):
        global PHASE
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/upload-check':
            try:
                port = int(urllib.parse.parse_qs(parsed.query)['port'][0])
                assert 1024 <= port <= 65535
                data = json.dumps(receive_from_engine(port)).encode()
            except Exception as error:
                data = json.dumps({'error': type(error).__name__ + ': ' + str(error)}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path == '/checkpoint': PHASE += 1
        if self.path == '/expected-sha256': data = hashlib.sha256(PAYLOAD).hexdigest().encode()
        elif self.path == '/checkpoint': data = b'ok'
        elif self.path == '/fixture.torrent': data = TORRENT
        elif self.path == '/multi.torrent': data = MULTI
        elif self.path == '/requests': data = json.dumps(REQUESTS).encode()
        elif self.path in ['/payload.bin', '/renewed.bin', '/queued.bin']: data = PAYLOAD
        elif self.path == '/changed.bin': data = PAYLOAD + b'x'
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
        # Control endpoints such as /checkpoint must reach the server on every call.
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('ETag', '"edm-changed-v2"' if self.path == '/changed.bin' else '"edm-fixture-v1"')
        self.send_header('Last-Modified', 'Wed, 11 Nov 2026 00:00:00 GMT')
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
