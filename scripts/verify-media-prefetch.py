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
parser.add_argument("--build-dir", type=Path, default=Path("build"), help="directory for disposable sources and binaries")
parser.add_argument("--resource-probe", action="store_true", help="add one file-backed 8-way 8 MiB VIDEO case and measure only the Swift runtime process peak RSS")
parser.add_argument("--cache-limit-gb", type=int, choices=(1, 5, 10, 20), help="test-only cache quota preference to use for preload budget cases (default: 20)")
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
active_video_transfers = 0
peak_video_transfers = 0
video_transfer_events = []
active_video_cases = {}
peak_video_cases = {}
concurrency_gate = threading.Event()
concurrency_video = video + struct.pack(">I4s", 1024 * 1024 - len(video), b"free") + bytes(1024 * 1024 - len(video) - 8)
build = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
build.mkdir(parents=True, exist_ok=True)
large_video_path = build / "concurrency61-file-backed-8MiB.mp4"
if args.resource_probe and not large_video_path.exists():
    free_size = 8 * 1024 * 1024 - len(video)
    if free_size < 8:
        raise SystemExit("the local MP4 fixture is too large for the 8 MiB test asset")
    with large_video_path.open("wb") as target:
        target.write(video)
        target.write(struct.pack(">I4s", free_size, b"free"))
        remaining = free_size - 8
        zeros = bytes(64 * 1024)
        while remaining:
            count = min(remaining, len(zeros))
            target.write(zeros[:count])
            remaining -= count

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        global started, active_video_transfers, peak_video_transfers
        if self.path == "/reset":
            with lock:
                requests.clear(); video_transfer_events.clear(); peak_video_transfers = 0; peak_video_cases.clear(); started = time.monotonic()
                concurrency_gate.clear()
            self.reply(b"ok", "text/plain"); return
        if self.path == "/release-concurrency":
            concurrency_gate.set(); self.reply(b"ok", "text/plain"); return
        if self.path == "/stats":
            with lock:
                data = json.dumps({"requests": {k: v["count"] for k, v in requests.items()}, "firstRequestMs": {k: v["firstMs"] for k, v in requests.items()}, "concurrencyVideoPeak": peak_video_transfers, "concurrencyVideoPeakByCase": peak_video_cases, "concurrencyVideoEvents": list(video_transfer_events)}).encode()
            self.reply(data, "application/json"); return
        with lock:
            row = requests.setdefault(self.path, {"count": 0, "firstMs": int((time.monotonic()-started)*1000)})
            row["count"] += 1
            nth = row["count"]
        if self.path.startswith("/concurrency61-"):
            large_case = self.path.startswith("/concurrency61-large-")
            case_key = self.path.rsplit("-", 1)[0].removeprefix("/")
            body_length = large_video_path.stat().st_size if large_case else len(concurrency_video)
            with lock:
                active_video_transfers += 1
                peak_video_transfers = max(peak_video_transfers, active_video_transfers)
                active_video_cases[case_key] = active_video_cases.get(case_key, 0) + 1
                peak_video_cases[case_key] = max(peak_video_cases.get(case_key, 0), active_video_cases[case_key])
                video_transfer_events.append({"path": self.path, "event": "start", "ms": int((time.monotonic()-started)*1000)})
            concurrency_gate.wait(timeout=10)
            self.send_response(200); self.send_header("Content-Type", "video/mp4"); self.send_header("Content-Length", str(body_length)); self.end_headers()
            try:
                if large_case:
                    source = large_video_path.open("rb")
                    read_chunk = lambda: source.read(64 * 1024)
                else:
                    offset = 0
                    def read_chunk():
                        nonlocal offset
                        if offset >= len(concurrency_video):
                            return b""
                        block = concurrency_video[offset:offset + 64 * 1024]
                        offset += len(block)
                        return block
                sent = 0
                while block := read_chunk():
                    self.wfile.write(block); self.wfile.flush()
                    with lock:
                        if sent == 0:
                            video_transfer_events.append({"path": self.path, "event": "firstByte", "ms": int((time.monotonic()-started)*1000)})
                        sent += len(block)
                        if sent >= body_length:
                            video_transfer_events.append({"path": self.path, "event": "lastByte", "ms": int((time.monotonic()-started)*1000)})
                    time.sleep(.005 if large_case else .01)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                if large_case:
                    source.close()
                with lock:
                    video_transfer_events.append({"path": self.path, "event": "end", "ms": int((time.monotonic()-started)*1000)})
                    active_video_transfers -= 1
                    active_video_cases[case_key] = max(0, active_video_cases.get(case_key, 1) - 1)
            return
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
if not report_path.is_absolute():
    report_path = root / report_path
try:
    swiftc_args = ["xcrun", "swiftc"]
    if args.baseline51:
        swiftc_args.append("-DLEGACY_PREFETCH51")
    subprocess.run([*swiftc_args, *map(str, sources), "-o", str(binary)], check=True, env=env)
    runtime_command = [str(binary), f"http://127.0.0.1:{port}", "--baseline51" if args.baseline51 else "--current"]
    if args.cache_limit_gb is not None:
        runtime_command.append(f"--cache-limit-gb={args.cache_limit_gb}")
    rss_file = build / f"{report_path.stem}-runtime-peak-rss.txt"
    if args.resource_probe:
        runtime_command.append("--resource-probe")
        runtime_command = ["/usr/bin/time", "-l", "-o", str(rss_file), *runtime_command]
    completed = subprocess.run(runtime_command, check=False, capture_output=True, text=True, env=env, timeout=90 if args.resource_probe else 45)
    if completed.returncode:
        raise RuntimeError(f"probe failed ({completed.returncode})\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}")
    observed = json.loads(completed.stdout.strip().splitlines()[-1])
    observed["sourceHashes"] = {
        "MediaCache.swift": hashlib.sha256((source_root / "CivitViewer/MediaCache.swift").read_bytes()).hexdigest(),
        "Models.swift": hashlib.sha256((source_root / "CivitViewer/Models.swift").read_bytes()).hexdigest(),
        **({"MediaPreloader.swift": hashlib.sha256((root / "CivitViewer/MediaPreloader.swift").read_bytes()).hexdigest()} if not args.baseline51 else {}),
        "compiledInputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    }
    observed["fixtureSha256"] = hashlib.sha256(video).hexdigest()
    observed["server"] = "127.0.0.1 temporary HTTPServer"
    if args.resource_probe:
        timing_output = rss_file.read_text()
        import re
        match = re.search(r"([0-9,]+)\s+maximum resident set size", timing_output)
        if not match:
            raise RuntimeError(f"could not parse /usr/bin/time -l output in {rss_file}:\n{timing_output}")
        peak_rss_bytes = int(match.group(1).replace(",", ""))
        observed["runtimeMemoryObservation"] = {
            "measuredProcess": "compiled Swift runtime probe only; swiftc was excluded",
            "measurement": "/usr/bin/time -l maximum resident set size",
            "peakResidentBytes": peak_rss_bytes,
            "peakResidentMiB": round(peak_rss_bytes / (1024 * 1024), 2),
            "rssOutput": str(rss_file),
            "workload": f"local file-backed 8-way VIDEO transfer, 8 x 8 MiB; aggregate responses 64 MiB; cache free-space provider 10 GB and cache size preference {args.cache_limit_gb or 20} GB",
            "transferSource": str(large_video_path),
        }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(observed, indent=2, sort_keys=True) + "\n")
    print(json.dumps(observed, indent=2, sort_keys=True))
finally:
    server.shutdown(); server.server_close()
