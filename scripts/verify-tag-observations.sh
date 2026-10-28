#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$(mktemp -d)"
trap 'rm -rf "$out_dir"' EXIT
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" \
  "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/TagConjunctionPager.swift" \
  "$task_root/CivitViewer/TagMediaAvailability.swift" \
  "$task_root/Tests/TagObservationChecks.swift" \
  -o "$out_dir/tag-observation-checks"
"$out_dir/tag-observation-checks"
