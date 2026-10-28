#!/usr/bin/env python3
"""Compile the actual bounded downloader and exercise only a local test server."""
from pathlib import Path
import http.server
import os
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[1]
source = (root / 'CivitViewer/MediaCache.swift').read_text()
actual = 'import Foundation\n' + source[source.index('enum MediaDownloadError:'):]
extracted = root / 'build/DownloadUnderTest.swift'
extracted.parent.mkdir(exist_ok=True)
extracted.write_text(actual)
env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}
binary = root / 'build/download-checks'
subprocess.run(['xcrun', 'swiftc', str(root / 'CivitViewer/VideoDuration.swift'), str(root / 'CivitViewer/Models.swift'), str(extracted), str(root / 'Tests/DownloadChecks.swift'), '-o', str(binary)], check=True, env=env)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        length = {'/valid': 4096, '/too-large': 8192, '/unknown-length': 8192, '/html': 64, '/slow': 1024 * 1024}.get(self.path)
        if length is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html' if self.path == '/html' else 'image/png')
        if self.path != '/unknown-length':
            self.send_header('Content-Length', str(length))
        self.end_headers()
        try:
            for offset in range(0, length, 512):
                self.wfile.write(b'x' * min(512, length - offset))
                self.wfile.flush()
                if self.path in ['/slow', '/unknown-length']:
                    time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'], check=True, env=env, timeout=30)
finally:
    server.shutdown()
    server.server_close()
