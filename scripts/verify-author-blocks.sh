#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingHistoryTypes.swift" \
  "$task_root/CivitViewer/AuthorBlocklist.swift" \
  "$task_root/Tests/AuthorBlocklistChecks.swift" \
  -o "$task_root/build/author-blocklist-checks"
"$task_root/build/author-blocklist-checks"
