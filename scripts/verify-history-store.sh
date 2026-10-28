#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/LocalDiagnostics.swift" "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" "$task_root/CivitViewer/BrowsingHistoryTypes.swift" "$task_root/CivitViewer/BrowsingHistoryDatabase.swift" "$task_root/CivitViewer/BrowsingHistory.swift" "$task_root/Tests/BrowsingHistoryStoreChecks.swift" -o "$task_root/build/browsing-history-store-checks"
"$task_root/build/browsing-history-store-checks"
