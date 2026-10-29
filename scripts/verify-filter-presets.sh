#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" \
  "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/FilterPresets.swift" \
  "$task_root/Tests/FilterPresetChecks.swift" \
  -o "$task_root/build/filter-preset-checks"
"$task_root/build/filter-preset-checks"
