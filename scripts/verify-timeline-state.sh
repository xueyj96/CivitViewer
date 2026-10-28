#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/FeedRequest.swift" \
  "$task_root/CivitViewer/BrowsingHistoryTypes.swift" \
  "$task_root/CivitViewer/TimelineState.swift" \
  "$task_root/Tests/TimelineStateChecks.swift" \
  -o "$task_root/build/timeline-state-checks"
"$task_root/build/timeline-state-checks"
