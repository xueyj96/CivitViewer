#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/PlaybackDiagnostics.swift" "$task_root/CivitViewer/LocalDiagnostics.swift" "$task_root/CivitViewer/LocalDiagnosticsView.swift" "$task_root/Tests/LocalDiagnosticsChecks.swift" -o "$task_root/build/local-diagnostics-checks"
"$task_root/build/local-diagnostics-checks"
