#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/MediaReading.swift" \
  "$task_root/CivitViewer/MediaRead.swift" \
  "$task_root/Tests/MediaReadChecks.swift" \
  -o "$task_root/build/media-read-checks"
"$task_root/build/media-read-checks"
