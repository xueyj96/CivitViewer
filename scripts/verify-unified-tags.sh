#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/PlaybackDiagnostics.swift" "$task_root/CivitViewer/LocalDiagnostics.swift" "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" "$task_root/CivitViewer/BrowsingPreferences.swift" "$task_root/CivitViewer/MediaSearch.swift" "$task_root/CivitViewer/LocalTagTypes.swift" "$task_root/CivitViewer/TagDirectory.swift" "$task_root/Tests/UnifiedTagChecks.swift" -o "$task_root/build/unified-tag-checks"
"$task_root/build/unified-tag-checks"
