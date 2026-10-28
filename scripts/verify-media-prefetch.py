#!/usr/bin/env python3
"""Compare frozen 51 and current media prefetch using disposable localhost assets."""
from pathlib import Path
import argparse, hashlib, http.server, json, os, struct, subprocess, threading, time, zlib

root = Path(__file__).resolve().parents[1]
versions = root.parent / "versions"
baseline = versions / "native-v3-build-51"
parser = argparse.ArgumentParser()
parser.add_argument("--baseline51", action="store_true", help="compile and run frozen build 51 sources")
parser.add_argument("--json", type=Path, help="save the observed report JSON (defaults to build/prefetch-result.json)")
args = parser.parse_args()
source_root = baseline if args.baseline51 else root
if not source_root.exists():
    raise SystemExit(f"baseline source tree missing: {source_root}")

def chunk(kind, data):
    return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 16, 16, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress((b"\0" + bytes((30, 120, 210)) * 16) * 16)) + chunk(b"IEND", b"")
fixture = root / "Tests/Fixtures/short.mp4"
if not fixture.is_file():
    raise SystemExit(f"required silent video fixture missing: {fixture}")
video = fixture.read_bytes()
lock = threading.Lock()
requests = {}
started = time.monotonic()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        global started
        if self.path == "/reset":
            with lock:
                requests.clear(); started = time.monotonic()
            self.reply(b"ok", "text/plain"); return
        if self.path == "/stats":
            with lock:
                data = json.dumps({"requests": {k: v["count"] for k, v in requests.items()}, "firstRequestMs": {k: v["firstMs"] for k, v in requests.items()}}).encode()
            self.reply(data, "application/json"); return
        with lock:
            row = requests.setdefault(self.path, {"count": 0, "firstMs": int((time.monotonic()-started)*1000)})
            row["count"] += 1
            nth = row["count"]
        if "recover-failure-image" in self.path or "recover-inflight-image" in self.path:
            if nth == 1:
                time.sleep(.15)
                self.reply(b'{"error":"temporary fixture failure"}', "application/json", code=503)
                return
        if self.path in ("/budget-video-a", "/budget-video-b"):
            size = 64 * 1024 * 1024
            self.send_response(200); self.send_header("Content-Type", "video/mp4"); self.send_header("Content-Length", str(size)); self.end_headers()
            try:
                self.wfile.write(video); remaining = size - len(video); block = b'\0' * (256 * 1024)
                while remaining:
                    count = min(remaining, len(block)); self.wfile.write(block[:count]); self.wfile.flush(); remaining -= count
                    time.sleep(.004)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if "poster" in self.path:
            time.sleep(.4)
        if "bounded-image" in self.path:
            time.sleep(.1)
        if self.path.endswith("video2") or self.path.endswith("c-video") or self.path.endswith("s-video") or self.path.endswith("x-video") or self.path.endswith("focus-video2"):
            time.sleep(1.3)
        if self.path.endswith("video") or "video" in self.path:
            body, mime = video, "video/mp4"
        else:
            body, mime = png, "image/png"
        self.reply(body, mime)
    def reply(self, body, mime, code=200):
        self.send_response(code); self.send_header("Content-Type", mime); self.send_header("Content-Length", str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_port
build = root / "build"
build.mkdir(exist_ok=True)
cache_source = (source_root / "CivitViewer/MediaCache.swift").read_text()
model_source = (source_root / "CivitViewer/Models.swift").read_text()
# Permit only loopback HTTP in the generated test copy; production source remains HTTPS-only.
model_source = model_source.replace('url.scheme == "https"', '(url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1"))')
cache_source = cache_source.replace("import UIKit", "import AppKit\ntypealias UIImage = NSImage\nextension NSImage { var scale: CGFloat { 1 }; func jpegData(compressionQuality: CGFloat) -> Data? { tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) } }; convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) } }", 1)
cache_file = build / "MediaCacheUnderTest.swift"
model_file = build / "ModelsUnderTest.swift"
cache_file.write_text(cache_source); model_file.write_text(model_source)
sources = [source_root / "CivitViewer/VideoDuration.swift", model_file,
           source_root / "CivitViewer/MediaLoadQueue.swift", source_root / "CivitViewer/MediaFormat.swift",
           source_root / "CivitViewer/MediaRepairStore.swift", source_root / "CivitViewer/PlaybackDiagnostics.swift",
           source_root / "CivitViewer/LocalDiagnostics.swift", cache_file]
if not args.baseline51:
    sources.append(root / "CivitViewer/MediaPreloader.swift")
sources.append(root / "Tests/MediaPrefetchChecks.swift")
binary = build / ("media-prefetch-51" if args.baseline51 else "media-prefetch-current")
env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
report_path = args.json or (build / ("ui51-prefetch.json" if args.baseline51 else "ui52-prefetch.json"))
try:
    swiftc_args = ["xcrun", "swiftc"]
    if args.baseline51:
        swiftc_args.append("-DLEGACY_PREFETCH51")
    subprocess.run([*swiftc_args, *map(str, sources), "-o", str(binary)], check=True, env=env)
    completed = subprocess.run([str(binary), f"http://127.0.0.1:{port}", "--baseline51" if args.baseline51 else "--current"], check=True, capture_output=True, text=True, env=env, timeout=45)
    observed = json.loads(completed.stdout.strip().splitlines()[-1])
    observed["sourceHashes"] = {
        "MediaCache.swift": hashlib.sha256((source_root / "CivitViewer/MediaCache.swift").read_bytes()).hexdigest(),
        "Models.swift": hashlib.sha256((source_root / "CivitViewer/Models.swift").read_bytes()).hexdigest(),
        **({"MediaPreloader.swift": hashlib.sha256((root / "CivitViewer/MediaPreloader.swift").read_bytes()).hexdigest()} if not args.baseline51 else {}),
        "compiledInputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    }
    observed["fixtureSha256"] = hashlib.sha256(video).hexdigest()
    observed["server"] = "127.0.0.1 temporary HTTPServer"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(observed, indent=2, sort_keys=True) + "\n")
    print(json.dumps(observed, indent=2, sort_keys=True))
finally:
    server.shutdown(); server.server_close()
