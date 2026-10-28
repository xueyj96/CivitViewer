#!/usr/bin/env python3
"""Build, run, collect, and uninstall a simulator-only synthetic C engine probe."""
from __future__ import annotations

import argparse
import json
import plistlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build" / "media-engine47-probe"
BUNDLE_ID = "com.xueyj.CivitRepairEngineProbe47"
SIMULATOR = "73E8D01A-F36B-4097-934C-EAD60B1A4D0B"
SOURCE_FRAMEWORK = ROOT / "build" / "media-engine47" / "ios-simulator-arm64" / "CivitMediaEngine.framework"


def run(args: list[str], *, log=None, check=True):
    if log is not None:
        log.write("$ " + " ".join(map(str, args)) + "\n")
        log.flush()
    return subprocess.run(args, check=check, text=True, stdout=log, stderr=subprocess.STDOUT if log else None)


def create_fixtures(directory: Path, log) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg command is required for synthetic fixture generation")
    base = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "8", "-an", "-pix_fmt", "yuv420p", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", str(directory / "vp9.webm")], log=log)
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "4", "-an", "-pix_fmt", "yuv420p", "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", str(directory / "vp8.webm")], log=log)
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4", "-shortest", "-pix_fmt", "yuv420p", "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", "-c:a", "libopus", "-b:a", "64k", str(directory / "opus-vp8.webm")], log=log)
    # Deliberately retain source timestamps after dropping a synthetic middle audio interval.
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000:duration=4", "-filter_complex", "[1:a]aselect=not(between(t\\,1.25\\,2.25))[agap]", "-map", "0:v:0", "-map", "[agap]", "-t", "4", "-pix_fmt", "yuv420p", "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", "-c:a", "libopus", "-b:a", "64k", str(directory / "audio-gap-vp8.webm")], log=log)
    rotated_base = directory / "rotated-base.mp4"
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "4", "-an", "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", str(rotated_base)], log=log)
    run(base + ["-display_rotation:v:0", "90", "-i", str(rotated_base), "-map", "0:v:0", "-c", "copy", str(directory / "rotated-h264.mp4")], log=log)
    run(base + ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-t", "8", "-an", "-pix_fmt", "yuv420p", "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "1200k", str(directory / "cancel-vp8.webm")], log=log)
    (directory / "not-video.html").write_text("<!doctype html><video></video>", encoding="utf-8")
    (directory / "damaged.webm").write_bytes(b"not-a-webm-container\x00" * 64)


def ffprobe(path: Path) -> dict:
    value = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries",
        "format=format_name,duration:stream=index,codec_type,codec_name,width,height:stream_side_data=rotation",
        "-of", "json", str(path)
    ], text=True)
    data = json.loads(value)
    streams = data.get("streams", [])
    audio = any(stream.get("codec_type") == "audio" for stream in streams)
    video = next((stream for stream in streams if stream.get("codec_type") == "video"), {})
    rotation = None
    for side_data in video.get("side_data_list", []):
        if "rotation" in side_data:
            rotation = side_data["rotation"]
    return {
        "format": data.get("format", {}).get("format_name", ""),
        "duration": float(data.get("format", {}).get("duration", "0") or 0),
        "videoCodec": video.get("codec_name", ""),
        "width": int(video.get("width", 0)),
        "height": int(video.get("height", 0)),
        "hasAudio": audio,
        "audioCodec": next((stream.get("codec_name", "") for stream in streams if stream.get("codec_type") == "audio"), ""),
        "rotation": rotation,
    }


def max_audio_gap(path: Path) -> float:
    data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets", "-show_entries", "packet=pts_time,duration_time", "-of", "json", str(path)], text=True))
    intervals = []
    for packet in data.get("packets", []):
        try:
            start = float(packet["pts_time"]); duration = float(packet.get("duration_time", 0))
            intervals.append((start, start + duration))
        except (KeyError, TypeError, ValueError):
            continue
    intervals.sort()
    return max((max(0.0, right[0] - left[1]) for left, right in zip(intervals, intervals[1:])), default=0.0)


def sim_container(kind: str) -> str:
    return subprocess.check_output(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE_ID, kind], text=True, stderr=subprocess.DEVNULL).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cancel-only", action="store_true", help="run only the in-flight cancellation probe")
    args = parser.parse_args()
    if WORK.exists():
        for item in (WORK / "Payload", WORK / "fixtures"):
            if item.exists():
                shutil.rmtree(item)
        for item in (WORK / "run.log", WORK / "results.json"):
            if item.exists():
                item.unlink()
    fixtures = WORK / "fixtures"
    app = WORK / "Payload" / f"{BUNDLE_ID}.app"
    framework_dir = app / "Frameworks"
    app.mkdir(parents=True)
    log_path = WORK / "run.log"
    with log_path.open("w", encoding="utf-8") as log:
        create_fixtures(fixtures, log)
        for name in ("vp9.webm", "vp8.webm", "opus-vp8.webm", "rotated-h264.mp4"):
            log.write(f"FIXTURE {name} {json.dumps(ffprobe(fixtures / name), sort_keys=True)}\n")
        shutil.copytree(SOURCE_FRAMEWORK, framework_dir / "CivitMediaEngine.framework")
        sim_sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        swiftc = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        source = ROOT / "Tests" / "MediaRepairEngineProbe.swift"
        executable = app / BUNDLE_ID
        run([swiftc, "-parse-as-library", "-sdk", sim_sdk, "-target", "arm64-apple-ios17.0-simulator",
             "-F", str(SOURCE_FRAMEWORK.parent), "-framework", "CivitMediaEngine",
             "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
             "-o", str(executable), str(source)], log=log)
        app_fixtures = app / "fixtures"
        app_fixtures.mkdir()
        for name in ("vp9.webm", "vp8.webm", "opus-vp8.webm", "rotated-h264.mp4", "cancel-vp8.webm", "audio-gap-vp8.webm", "not-video.html", "damaged.webm"):
            shutil.copy2(fixtures / name, app_fixtures / name)
        plist = {
            "CFBundleExecutable": BUNDLE_ID,
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleName": "CivitRepairEngineProbe47",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSRequiresIPhoneOS": True,
            "MinimumOSVersion": "17.0",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
            "UILaunchScreen": {},
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        }
        (app / "Info.plist").write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=True))
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(framework_dir / "CivitMediaEngine.framework")], log=log)
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], log=log)

    installed = False
    final_report = {"status": "incomplete", "scope": "Synthetic fixtures only; no external requests or user data"}
    try:
        run(["xcrun", "simctl", "install", SIMULATOR, str(app)])
        installed = True
        launch = ["xcrun", "simctl", "launch", SIMULATOR, BUNDLE_ID]
        if args.cancel_only:
            launch.append("--qa-cancel-only")
        run(launch)
        data_container = Path(sim_container("data"))
        result_file = data_container / "Documents" / "results.json"
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not result_file.is_file():
            time.sleep(0.5)
        if not result_file.is_file():
            raise TimeoutError("Probe app did not write a results file within 120 seconds")
        raw = json.loads(result_file.read_text(encoding="utf-8"))
        final_report = raw
        output_dir = data_container / "Documents" / "output"
        outputs = {
            "vp9Remux": "vp9-remux.mp4",
            "vp8H264": "vp8-h264.mp4",
            "opusH264AAC": "opus-h264-aac.mp4",
            "rotatedH264": "rotated-h264-copy.mp4",
        }
        final_report["ffprobeOutputs"] = {}
        for label, filename in outputs.items():
            path = output_dir / filename
            if path.is_file():
                final_report["ffprobeOutputs"][label] = ffprobe(path)
        final_report["simulator"] = "iOS 27 simulator 73E8D01A-F36B-4097-934C-EAD60B1A4D0B"
        final_report["bundleId"] = BUNDLE_ID
        final_report["runMode"] = "cancel-only" if args.cancel_only else "full-matrix"
        final_report["generatedFixtures"] = {name: ffprobe(fixtures / name) for name in ("vp9.webm", "vp8.webm", "opus-vp8.webm", "audio-gap-vp8.webm", "rotated-h264.mp4")}
        final_report["generatedFixtures"]["audio-gap-vp8.webm"]["maxAudioGapSeconds"] = max_audio_gap(fixtures / "audio-gap-vp8.webm")
        final_report["status"] = "complete"
        (WORK / "results.json").write_text(json.dumps(final_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except Exception as error:
        final_report["failure"] = {"type": type(error).__name__}
        (WORK / "results.json").write_text(json.dumps(final_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        raise
    finally:
        if installed:
            subprocess.run(["xcrun", "simctl", "terminate", SIMULATOR, BUNDLE_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run(["xcrun", "simctl", "uninstall", SIMULATOR, BUNDLE_ID], check=True)
        absent = subprocess.run(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE_ID, "app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
        final_report["probeAppUninstalled"] = absent
        final_report["status"] = final_report.get("status", "incomplete") if absent else "cleanup_failed"
        (WORK / "results.json").write_text(json.dumps(final_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        if not absent:
            raise RuntimeError("Probe app remains installed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Probe failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise
