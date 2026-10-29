#!/usr/bin/env python3
"""Three-run localhost-only before/after probe for continuous video prefetch."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import struct
import statistics
import select
import socket
import subprocess
import threading
import time
import urllib.parse
import zlib

ROOT = Path(__file__).resolve().parents[1]
BASELINE_COMMIT = "d81d3bc15193a89d12884058fbb8a082e6cb24c2"
SOURCE_NAMES = [
    "VideoDuration.swift", "Models.swift", "MediaLoadQueue.swift", "MediaFormat.swift",
    "MediaRepairStore.swift", "PlaybackDiagnostics.swift", "LocalDiagnostics.swift", "MediaCache.swift",
]
FIXTURE = ROOT / "Tests/Fixtures/short.mp4"
OUT = ROOT / "build/continuous59"
PADDED_SIZE = 8 * 1024 * 1024
APKIT_BRIDGE = '''import AppKit\ntypealias UIImage = NSImage\nextension NSImage { var scale: CGFloat { 1 }; func jpegData(compressionQuality: CGFloat) -> Data? { tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) } }; convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) } }'''


class State:
    def __init__(self, fixture: bytes, png: bytes):
        self.fixture = fixture
        self.png = png
        self.image_gate = threading.Event()
        self.lock = threading.Lock()
        self.events: list[dict] = []
        self.marks: dict[str, int] = {}
        self.active = 0
        self.max_active = 0
        self.origin = time.monotonic()

    def reset(self):
        with self.lock:
            self.events.clear()
            self.marks.clear()
            self.image_gate.clear()
            self.active = self.max_active = 0
            self.origin = time.monotonic()

    def now(self):
        return int((time.monotonic() - self.origin) * 1000)


def create_server(state: State):
    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def wait_for_client_close(self, seconds: float, row: dict) -> bool:
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                readable, _, _ = select.select([self.connection], [], [], 0.01)
                if not readable:
                    continue
                try:
                    if not self.connection.recv(1, socket.MSG_PEEK):
                        with state.lock:
                            row["aborted"] = True
                        return True
                except OSError:
                    with state.lock:
                        row["aborted"] = True
                    return True
            return False

        def wait_image_gate(self, row: dict) -> bool:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                if state.image_gate.wait(0.01):
                    return False
                readable, _, _ = select.select([self.connection], [], [], 0)
                if readable:
                    try:
                        if not self.connection.recv(1, socket.MSG_PEEK):
                            with state.lock:
                                row["aborted"] = True
                            return True
                    except OSError:
                        with state.lock:
                            row["aborted"] = True
                        return True
            return False

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path == "/reset":
                state.reset()
                return self.reply(b"ok", "text/plain")
            if parsed.path == "/mark":
                with state.lock:
                    state.marks[query.get("name", [""])[0]] = state.now()
                return self.reply(b"ok", "text/plain")
            if parsed.path == "/release-image-gate":
                state.image_gate.set()
                return self.reply(b"ok", "text/plain")
            if parsed.path == "/stats":
                with state.lock:
                    result = {"requests": {}, "events": [dict(row) for row in state.events],
                              "marks": dict(state.marks), "maxActive": state.max_active,
                              "elapsedMs": state.now()}
                    for row in state.events:
                        result["requests"][row["path"]] = result["requests"].get(row["path"], 0) + 1
                return self.reply(json.dumps(result).encode(), "application/json")

            path = parsed.path
            ranged = self.headers.get("Range", "")
            is_image = parsed.path == "/handoff-image.png"
            source = state.png if is_image else state.fixture
            start = 0
            end = len(source) - 1
            if ranged.startswith("bytes="):
                try:
                    spec = ranged[6:].split(",", 1)[0]
                    left, right = spec.split("-", 1)
                    start = int(left or 0)
                    end = min(end, int(right)) if right else end
                except ValueError:
                    pass
            body = source[start:end + 1]
            with state.lock:
                row = {"path": path, "range": ranged or None, "startMs": state.now(), "endMs": None,
                       "firstByteMs": None, "lastByteMs": None, "bytes": 0,
                       "aborted": False, "status": 206 if ranged else 200}
                state.events.append(row)
                state.active += 1
                state.max_active = max(state.max_active, state.active)
            try:
                self.send_response(row["status"])
                self.send_header("Content-Type", "image/png" if is_image else "video/mp4")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(len(body)))
                if ranged:
                    self.send_header("Content-Range", f"bytes {start}-{start + len(body) - 1}/{len(source)}")
                self.send_header("Connection", "close")
                self.end_headers()
                if path.startswith("/w") and path.endswith(("-4.mp4", "-5.mp4")):
                    # A fixed server-side gate makes cancellation observable. It is
                    # released after one second if the client does not cancel.
                    if self.wait_for_client_close(1.0, row):
                        return
                elif is_image:
                    if self.wait_image_gate(row):
                        return
                elif path.startswith("/play-"):
                    # Leave a real cache flight active while AVPlayer opens a
                    # second localhost request to the same legal MP4.
                    if self.wait_for_client_close(0.45, row):
                        return
                try:
                    for offset in range(0, len(body), 64 * 1024):
                        block = body[offset:offset + 64 * 1024]
                        if row["firstByteMs"] is None:
                            with state.lock:
                                row["firstByteMs"] = state.now()
                        self.wfile.write(block)
                        self.wfile.flush()
                        with state.lock:
                            row["bytes"] += len(block)
                            row["lastByteMs"] = state.now()
                        if len(body) > 64 * 1024:
                            time.sleep(0.003)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    with state.lock:
                        row["aborted"] = True
            finally:
                with state.lock:
                    row["endMs"] = state.now()
                    state.active = max(0, state.active - 1)

        def reply(self, body: bytes, mime: str):
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def source_tree(label: str, baseline: bool, cancel_current_image_control: bool = False) -> tuple[Path, list[Path]]:
    target = OUT / label / "source"
    if target.exists():
        shutil.rmtree(target)
    (target / "CivitViewer").mkdir(parents=True)
    (target / "Tests").mkdir()
    for name in SOURCE_NAMES:
        relative = f"CivitViewer/{name}"
        if baseline:
            completed = subprocess.run(["git", "show", f"{BASELINE_COMMIT}:{relative}"], cwd=ROOT,
                                       check=True, capture_output=True)
            data = completed.stdout
        else:
            data = (ROOT / relative).read_bytes()
        (target / relative).write_bytes(data)
    if baseline:
        preloader = subprocess.run(["git", "show", f"{BASELINE_COMMIT}:CivitViewer/MediaPreloader.swift"], cwd=ROOT,
                                   check=True, capture_output=True).stdout
        (target / "CivitViewer/MediaPreloader.swift").write_bytes(preloader)
    else:
        shutil.copy2(ROOT / "CivitViewer/MediaPreloader.swift", target / "CivitViewer/MediaPreloader.swift")
    if cancel_current_image_control:
        preloader_path = target / "CivitViewer/MediaPreloader.swift"
        source = preloader_path.read_text()
        old_line = "let expiredJobs = jobs.keys.filter { !newSet.contains($0) && $0 != currentKey }"
        new_line = "let expiredJobs = jobs.keys.filter { !newSet.contains($0) }"
        if old_line not in source:
            raise RuntimeError("legacy image cancel control can only be made from the pinned baseline preloader")
        preloader_path.write_text(source.replace(old_line, new_line, 1))
    model = (target / "CivitViewer/Models.swift").read_text()
    model = model.replace('url.scheme == "https"', '(url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1"))')
    (target / "CivitViewer/Models.swift").write_text(model)
    cache_path = target / "CivitViewer/MediaCache.swift"
    cache = cache_path.read_text().replace("import UIKit", APKIT_BRIDGE, 1)
    cache_path.write_text(cache)
    shutil.copy2(ROOT / "Tests/ContinuousPrefetchChecks.swift", target / "Tests/ContinuousPrefetchChecks.swift")
    shutil.copy2(OUT / "short-padded.mp4", target / "short.mp4")
    sources = [target / "CivitViewer" / name for name in SOURCE_NAMES]
    sources += [target / "CivitViewer/MediaPreloader.swift", target / "Tests/ContinuousPrefetchChecks.swift"]
    return target, sources


def compile_and_run(label: str, baseline: bool, base_url: str, state: State,
                    cancel_current_image_control: bool = False) -> dict:
    tree, sources = source_tree(label, baseline, cancel_current_image_control)
    binary = OUT / label / "continuous-prefetch-checks"
    args = ["xcrun", "swiftc"]
    if baseline:
        args.append("-DBASELINE_CONTINUOUS59")
    if cancel_current_image_control:
        args.append("-DLEGACY_CANCEL_CURRENT_IMAGE59")
    args += [*map(str, sources), "-o", str(binary)]
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
    subprocess.run(args, cwd=ROOT, check=True, env=env)
    state.reset()
    run_env = {**env, "CONTINUOUS59_BASELINE": "1" if baseline else "0",
               "CONTINUOUS59_CONTROL": "cancel-current-image" if cancel_current_image_control else "none"}
    completed = subprocess.run([str(binary), base_url, str(tree / "short.mp4")], cwd=tree, capture_output=True, text=True,
                               check=False, timeout=75, env=run_env)
    if completed.returncode:
        raise RuntimeError(f"{label} probe exited {completed.returncode}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}")
    payloads = [line.removeprefix("CONTINUOUS59_JSON=") for line in completed.stdout.splitlines()
                if line.startswith("CONTINUOUS59_JSON=")]
    if not payloads:
        raise RuntimeError(f"{label} probe produced no marked JSON\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}")
    result = json.loads(payloads[-1])
    result["compiledInputs"] = {str(path.relative_to(tree)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    result["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    result["baselineCommit"] = BASELINE_COMMIT if baseline else None
    return result


def summarize(rows: list[dict], key: str):
    values = sorted(value for row in rows if isinstance((value := row.get(key)), (int, float)))
    return {"samples": values, "min": min(values) if values else None,
            "median": statistics.median(values) if values else None, "max": max(values) if values else None,
            "percentileClaims": "none (3 raw runs)"}


def main():
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--baseline-only", action="store_true", help="run the immutable baseline while current API work is in progress")
    modes.add_argument("--current-only", action="store_true", help="reuse baseline results in compare.json and measure the current working tree")
    args = parser.parse_args()
    if not FIXTURE.is_file():
        raise SystemExit(f"legal local silent MP4 fixture missing: {FIXTURE}")
    OUT.mkdir(parents=True, exist_ok=True)
    original = FIXTURE.read_bytes()
    free_size = PADDED_SIZE - len(original)
    if free_size < 8:
        raise SystemExit("padding target must leave room for an MP4 free atom")
    fixture = original + struct.pack(">I4s", free_size, b"free") + bytes(free_size - 8)
    (OUT / "short-padded.mp4").write_bytes(fixture)
    def png_chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
           png_chunk(b"IDAT", zlib.compress((b"\0" + bytes((30, 120, 210)) * 16) * 16)) + png_chunk(b"IEND", b""))
    state = State(fixture, png)
    server = create_server(state)
    base_url = f"http://127.0.0.1:{server.server_port}"
    try:
        if args.current_only:
            report_path = OUT / "compare.json"
            if not report_path.is_file():
                raise SystemExit("--current-only needs an existing compare.json with a verified baseline")
            report = json.loads(report_path.read_text())
            if report.get("baselineCommit") != BASELINE_COMMIT or "baseline" not in report:
                raise SystemExit("existing compare.json does not contain the expected immutable baseline")
        else:
            baseline_result = compile_and_run("baseline", True, base_url, state)
            report = {
                "schema": "continuous-prefetch-comparison-v1", "baselineCommit": BASELINE_COMMIT,
                "constraints": {"network": "localhost only, bound to 127.0.0.1", "source": "actual MediaCache.preloadFile/MediaPreloader and AVFoundation AVPlayer", "coldCacheRuns": 3, "percentileClaims": "none", "ui": "no app UI, login, or external site access", "fixtureSha256": hashlib.sha256(fixture).hexdigest(), "fixtureBytes": len(fixture), "fixtureConstruction": "existing silent playable MP4 plus a standards-compliant trailing free atom; localhost responses streamed in 64KiB chunks"},
                "baseline": baseline_result,
                "baselineSummary": {
                    "nearFirstRequestMsFromReverse": summarize(baseline_result["windowScheduler"], "nearFirstRequestMsFromReverse"),
                    "foregroundItemReadyMs": summarize(baseline_result["foregroundPlayback"], "itemReadyMs"),
                },
            }
            control_result = compile_and_run("image-cancel-control", True, base_url, state,
                                             cancel_current_image_control=True)
            report["imageCancelRegressionControl"] = {
                "description": "isolated copy of the pinned baseline with only the expiredJobs currentKey exemption removed; synthetic control, not a released baseline",
                "singleLineSourceTransformation": "jobs.keys.filter { !newSet.contains($0) && $0 != currentKey } -> jobs.keys.filter { !newSet.contains($0) }",
                "result": control_result["imageHandoff"],
                "compiledInputs": control_result["compiledInputs"],
            }
        if not args.baseline_only:
            current_result = compile_and_run("current", False, base_url, state)
            report["current"] = current_result
            report["currentSummary"] = {
                "nearFirstRequestMsFromReverse": summarize(current_result["windowScheduler"], "nearFirstRequestMsFromReverse"),
                "foregroundItemReadyMs": summarize(current_result["foregroundPlayback"], "itemReadyMs"),
            }
        out = OUT / "compare.json"
        out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report, indent=2, sort_keys=True))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
