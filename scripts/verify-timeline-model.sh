#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/FeedRequest.swift" \
  "$task_root/CivitViewer/BrowsingHistoryTypes.swift" \
  "$task_root/CivitViewer/BrowsingHistoryDatabase.swift" \
  "$task_root/CivitViewer/BrowsingHistory.swift" \
  "$task_root/CivitViewer/AuthorBlocklist.swift" \
  "$task_root/CivitViewer/TimelineState.swift" \
  "$task_root/CivitViewer/MediaReading.swift" \
  "$task_root/CivitViewer/FeedStore.swift" \
  "$task_root/CivitViewer/MediaRead.swift" \
  "$task_root/CivitViewer/TimelineModel.swift" \
  "$task_root/Tests/TimelineModelChecks.swift" \
  -o "$task_root/build/timeline-model-checks"
"$task_root/build/timeline-model-checks"
