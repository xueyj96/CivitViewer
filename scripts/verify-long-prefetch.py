#!/usr/bin/env python3
"""Compare frozen build 52 and current long-video prefetch with streamed loopback data."""
from pathlib import Path
import argparse
import hashlib
import http.server
import json
import os
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[1]
baseline = root.parent / "versions" / "native-v3-build-52"
parser = argparse.ArgumentParser()
parser.add_argument("--baseline52", action="store_true", help="compile and run frozen build 52 sources")
parser.add_argument("--json", type=Path, help="save observed report JSON (defaults to build/long-prefetch-result.json)")
args = parser.parse_args()
source_root = baseline if args.baseline52 else root
if not source_root.is_dir():
    raise SystemExit(f"source tree missing: {source_root}")

fixture = root / "Tests" / "Fixtures" / "short.mp4"
if not fixture.is_file():
    raise SystemExit(f"required neutral short MP4 prefix missing: {fixture}")
prefix = fixture.read_bytes()
long_size = 96 * 1024 * 1024
cap_plus = 512 * 1024 * 1024 + 1
lock = threading.Lock()
counts = {}
started = time.monotonic()
release_foreground40 = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global started
        if self.path == "/reset":
            with lock:
                counts.clear()
                started = time.monotonic()
            release_foreground40.clear()
            self.reply(b"ok", "text/plain")
            return
        if self.path == "/release-foreground40":
            release_foreground40.set()
            self.reply(b"released", "text/plain")
            return
        if self.path == "/stats":
            with lock:
                body = json.dumps({"requests": dict(counts)}).encode()
            self.reply(body, "application/json")
            return
        with lock:
            counts[self.path] = counts.get(self.path, 0) + 1
        if self.path == "/foreground-40":
            release_foreground40.wait(timeout=45)
            self.stream(40 * 1024 * 1024, delay=0.001)
            return
        if self.path in ("/over-cap",):
            # Advertise a body above the hard cap and stream only a few blocks.
            self.stream(cap_plus, stop_after=4)
            return
        if self.path == "/seed-video":
            self.reply(prefix, "video/mp4")
            return
        if self.path == "/cancel-long":
            self.stream(long_size, delay=0.01)
            return
        if self.path in ("/shared-a", "/shared-b", "/same-flight"):
            self.stream(8 * 1024 * 1024 if self.path == "/same-flight" else long_size, delay=0.003)
            return
        if self.path == "/quota-96":
            self.stream(long_size, delay=0.006)
            return
        if self.path in ("/long-96", "/long-96-small"):
            self.stream(long_size, delay=0.001)
            return
        self.reply(b"not found", "text/plain", 404)

    def stream(self, size, stop_after=None, delay=0.0):
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        block = b"\0" * (256 * 1024)
        remaining = size
        sent = 0
        try:
            first = min(len(prefix), remaining)
            self.wfile.write(prefix[:first])
            self.wfile.flush()
            sent += first
            remaining -= first
            while remaining and (stop_after is None or sent < stop_after * len(block)):
                amount = min(len(block), remaining)
                self.wfile.write(block[:amount])
                self.wfile.flush()
                remaining -= amount
                sent += amount
                if delay:
                    time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reply(self, body, mime, code=200):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()

build = root / "build"
build.mkdir(exist_ok=True)
cache_source = (source_root / "CivitViewer" / "MediaCache.swift").read_text()
model_source = (source_root / "CivitViewer" / "Models.swift").read_text()
# The generated test copy accepts only the loopback HTTP fixture. Production Models.swift stays unchanged.
model_source = model_source.replace('url.scheme == "https"', '(url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1"))')
cache_file = build / "LongPrefetchMediaCacheUnderTest.swift"
model_file = build / "LongPrefetchModelsUnderTest.swift"
cache_file.write_text(cache_source.replace(
    "import UIKit",
    "import AppKit\ntypealias UIImage = NSImage\nextension NSImage { var scale: CGFloat { 1 }; func jpegData(compressionQuality: CGFloat) -> Data? { tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) } }; convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) } }",
    1,
))
model_file.write_text(model_source)
inputs = [
    source_root / "CivitViewer" / "VideoDuration.swift",
    model_file,
    source_root / "CivitViewer" / "MediaLoadQueue.swift",
    source_root / "CivitViewer" / "MediaFormat.swift",
    source_root / "CivitViewer" / "MediaRepairStore.swift",
    source_root / "CivitViewer" / "PlaybackDiagnostics.swift",
    source_root / "CivitViewer" / "LocalDiagnostics.swift",
    cache_file,
    root / "Tests" / "LongPrefetchChecks.swift",
]
binary = build / ("long-prefetch-52" if args.baseline52 else "long-prefetch-current")
report_path = args.json or (build / ("long-prefetch-52.json" if args.baseline52 else "long-prefetch-current.json"))
try:
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "LONG_PREFETCH_SOURCE_HASH": hashlib.sha256(b"".join(p.read_bytes() for p in inputs)).hexdigest()}
    command = ["xcrun", "swiftc"]
    if args.baseline52:
        command.append("-DLEGACY_PREFETCH52")
    subprocess.run([*command, *map(str, inputs), "-o", str(binary)], check=True, env=env)
    mode = "--baseline52" if args.baseline52 else "--current53"
    completed = subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}", mode],
                               capture_output=True, text=True, env=env, timeout=60)
    if completed.returncode:
        print(completed.stderr[-7000:], flush=True)
        print(completed.stdout[-2000:], flush=True)
        completed.check_returncode()
    report = json.loads(completed.stdout.strip().splitlines()[-1])
    report["sourceHashes"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    report["fixture"] = {"path": "Tests/Fixtures/short.mp4", "sha256": hashlib.sha256(prefix).hexdigest(),
                         "prefixBytes": len(prefix), "description": "neutral short MP4 prefix followed by streamed zero padding; padding is cache-size workload, not valid video duration or playable media"}
    report["httpServer"] = "temporary loopback-only HTTPServer"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
finally:
    server.shutdown()
    server.server_close()
