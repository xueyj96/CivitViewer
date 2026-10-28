#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sim="73E8D01A-F36B-4097-934C-EAD60B1A4D0B"
bundle="com.xueyj.civitviewer"
derived="$root/build/resume-prompt-fixed-derived"
app="$derived/Build/Products/Debug-iphonesimulator/CivitViewer.app"
qaRel="Library/Caches/CivitResumePromptQA-native-fixed"
matrixID="resume-five-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
evidence="$root/build/resume-prompt-fixed-evidence-runs/$matrixID"
mkdir -p "$evidence"

sourceManifest="$evidence/source-manifest.sha256"
(
  cd "$root"
  { find CivitViewer -type f -print0; printf '%s\0' 'CivitViewer.xcodeproj/project.pbxproj'; } |
    sort -z | while IFS= read -r -d '' file; do shasum -a 256 "$file"; done
) > "$sourceManifest"
sourceSHA="$(shasum -a 256 "$sourceManifest" | awk '{print $1}')"

xcodebuild -quiet -project "$root/CivitViewer.xcodeproj" -scheme CivitViewer \
  -configuration Debug -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
buildSHA="$(find "$app" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
xcrun simctl install "$sim" "$app"

wait_for() {
  local file="$1" timeout="${2:-60}" started now
  started="$(date +%s)"
  while [[ ! -s "$file" ]]; do
    now="$(date +%s)"
    if (( now - started >= timeout )); then echo "TIMEOUT $file" >&2; return 1; fi
    sleep 0.1
  done
}
clear_qa_root() {
  local container qa
  container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
  qa="$container/$qaRel"
  python3 -c 'import pathlib,shutil,sys; shutil.rmtree(pathlib.Path(sys.argv[1]), ignore_errors=True)' "$qa"
}
scenario_dir() {
  local scenario="$1" runID="$2"
  echo "$evidence/$scenario-$runID"
}
write_receipt() {
  local scenario="$1" runID="$2" out="$3" startUTC="$4" endUTC="$5" scope="$6" lifecycle="$7"
  local artifactManifest="$out/artifacts.sha256" artifactSHA
  (cd "$out" && find . -maxdepth 1 -type f \( -name '*.png' -o -name '*.json' -o -name 'history.json' \) -print0 | sort -z | xargs -0 shasum -a 256) > "$artifactManifest"
  artifactSHA="$(shasum -a 256 "$artifactManifest" | awk '{print $1}')"
  cp "$sourceManifest" "$out/source-manifest.sha256"
  cat > "$out/receipt.json" <<EOF_RECEIPT
{
  "matrixID": "$matrixID",
  "runID": "$runID",
  "scenario": "$scenario",
  "scenarioScope": "$scope",
  "simulatorUDID": "$sim",
  "startUTC": "$startUTC",
  "endUTC": "$endUTC",
  "sourceManifestSHA256": "$sourceSHA",
  "builtAppFilesSHA256": "$buildSHA",
  "artifactManifestSHA256": "$artifactSHA",
  "signingAllowed": false,
  "lifecycleReadback": "$lifecycle",
  "evidenceFromSingleRun": true
}
EOF_RECEIPT
}
launch_case() {
  local scenario="$1" runID="$2"
  clear_qa_root
  xcrun simctl launch --terminate-running-process "$sim" "$bundle" \
    --qa-resume-prompt --qa-resume-prompt-reset "--qa-scenario=$scenario" "--qa-run-id=$runID" >/dev/null
  local container
  container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
  echo "$container/$qaRel"
}
capture_image() { xcrun simctl io "$sim" screenshot "$1" >/dev/null; }
copy_snapshot() { cp "$1/$2.json" "$3/$4.json"; }

run_flow() {
  local scenario="$1" runID startUTC endUTC out qa scope lifecycle
  runID="$scenario-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  startUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(scenario_dir "$scenario" "$runID")"
  mkdir -p "$out"
  if [[ "$scenario" == "dismiss" ]]; then scope="preseeded checkpoint → production dismissPrompt → actual next focus → 2s TimelineLane exposure → refresh/tab cycle"; else scope="preseeded checkpoint → production TimelineModel.restore → actual next focus → 2s TimelineLane exposure → refresh/tab cycle"; fi
  qa="$(launch_case "$scenario" "$runID")"
  wait_for "$qa/initial.json" 60
  wait_for "$qa/initial-layout-ready.json" 20
  wait_for "$qa/waiting-dismiss-$scenario.json" 20
  sleep 0.2
  capture_image "$out/01-initial.png"
  copy_snapshot "$qa" "initial-layout-ready" "$out" "initial"
  printf 'ack\n' > "$qa/ack-dismiss-$scenario"
  if [[ "$scenario" == "dismiss" ]]; then wait_for "$qa/after-dismiss.json" 30; copy_snapshot "$qa" after-dismiss "$out" after-dismiss
  else wait_for "$qa/after-restore.json" 30; copy_snapshot "$qa" after-restore "$out" after-restore; fi
  capture_image "$out/02-consumed.png"
  wait_for "$qa/waiting-next-$scenario.json" 20
  printf 'ack\n' > "$qa/ack-next-$scenario"
  wait_for "$qa/focus-next.json" 30
  copy_snapshot "$qa" focus-next "$out" focus-next
  wait_for "$qa/after-exposure.json" 30
  capture_image "$out/03-after-exposure.png"
  copy_snapshot "$qa" after-exposure "$out" after-exposure
  wait_for "$qa/waiting-refresh-$scenario.json" 20
  printf 'ack\n' > "$qa/ack-refresh-$scenario"
  wait_for "$qa/waiting-capture-tab-return-1s.json" 30
  sleep 1
  capture_image "$out/04-tab-return-1s.png"
  printf 'ack\n' > "$qa/ack-capture-tab-return-1s"
  wait_for "$qa/tab-return-1s.json" 10
  copy_snapshot "$qa" tab-return-1s "$out" tab-return-1s
  wait_for "$qa/waiting-capture-tab-return-3s.json" 30
  sleep 2
  capture_image "$out/05-tab-return-3s.png"
  printf 'ack\n' > "$qa/ack-capture-tab-return-3s"
  wait_for "$qa/tab-return-3s.json" 10
  copy_snapshot "$qa" tab-return-3s "$out" tab-return-3s
  find "$qa" -name history.json -exec cp {} "$out/history.json" \;
  if xcrun simctl launch "$sim" com.apple.Preferences >/dev/null 2>&1 && wait_for "$qa/scene-background.json" 10 2>/dev/null; then
    xcrun simctl launch "$sim" "$bundle" >/dev/null 2>&1 || true
    if wait_for "$qa/scene-active.json" 10 2>/dev/null; then
      capture_image "$out/06-after-background-foreground.png"
      copy_snapshot "$qa" scene-background "$out" scene-background
      copy_snapshot "$qa" scene-active "$out" scene-active
      lifecycle="verified-background-and-active"
    else
      echo "UNTESTED: simulator app did not return to active scene" > "$out/lifecycle-UNTESTED.txt"
      lifecycle="untested-active-return"
    fi
  else
    echo "UNTESTED: simulator Settings launch did not produce a background scene readback" > "$out/lifecycle-UNTESTED.txt"
    lifecycle="untested-background"
  fi
  endUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_receipt "$scenario" "$runID" "$out" "$startUTC" "$endUTC" "$scope" "$lifecycle"
  echo "$scenario: $runID"
}
run_readback() {
  local scenario="$1" runID startUTC endUTC out qa container scope
  runID="$scenario-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  startUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="$(scenario_dir "$scenario" "$runID")"
  mkdir -p "$out"
  scope="independent seeded persisted checkpoint fixture on a fresh app process; not a restart of a preceding dismiss/exposure run"
  qa="$(launch_case "$scenario" "$runID")"
  wait_for "$qa/process-readback-$scenario.json" 60
  capture_image "$out/01-process-readback.png"
  copy_snapshot "$qa" "process-readback-$scenario" "$out" process-readback
  find "$qa" -name history.json -exec cp {} "$out/history.json" \;
  endUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_receipt "$scenario" "$runID" "$out" "$startUTC" "$endUTC" "$scope" "not-applicable-independent-seed"
  echo "$scenario: $runID"
}

run_flow dismiss
run_flow restore-success
run_flow restore-failure
run_readback readback-consumed
run_readback readback-new
python3 "$root/scripts/verify-resume-ui.py" "$evidence"
echo "Simulator: $sim"
echo "Evidence: $evidence"
