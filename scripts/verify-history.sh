#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" "$task_root/CivitViewer/BrowsingHistoryTypes.swift" "$task_root/CivitViewer/BrowsingHistoryDatabase.swift" "$task_root/Tests/BrowsingHistoryChecks.swift" -o "$task_root/build/browsing-history-checks"
"$task_root/build/browsing-history-checks"
