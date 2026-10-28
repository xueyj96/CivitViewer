#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/LocalDiagnostics.swift" "$task_root/CivitViewer/PlaybackDiagnostics.swift" "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" "$task_root/CivitViewer/BrowsingPreferences.swift" "$task_root/CivitViewer/MediaSearch.swift" "$task_root/CivitViewer/TagConjunctionPager.swift" "$task_root/Tests/TagConjunctionChecks.swift" -o "$task_root/build/tag-conjunction-checks"
"$task_root/build/tag-conjunction-checks"
