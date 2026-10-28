#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/VideoSeekControl.swift" "$task_root/Tests/VideoSeekChecks.swift" -o "$task_root/build/video-seek-checks"
"$task_root/build/video-seek-checks"
