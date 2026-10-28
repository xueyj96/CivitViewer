#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/FeedRequest.swift" \
  "$task_root/CivitViewer/CollectionRead.swift" \
  "$task_root/Tests/CoreChecks.swift" \
  -o "$task_root/build/core-checks"
"$task_root/build/core-checks"
