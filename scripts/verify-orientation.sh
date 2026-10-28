#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/ViewingOrientation.swift" "$task_root/Tests/ViewingOrientationChecks.swift" -o "$task_root/build/viewing-orientation-checks"
"$task_root/build/viewing-orientation-checks"
