#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
xcrun swiftc "$task_root/CivitViewer/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/LocalTagTypes.swift" "$task_root/Tests/SiteCooldownChecks.swift" \
  -o "$task_tmp/site-cooldown-checks"
"$task_tmp/site-cooldown-checks"
