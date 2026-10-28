#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sim="73E8D01A-F36B-4097-934C-EAD60B1A4D0B"
bundle="com.xueyj.civitviewer"
derived="$root/build/resume-prompt-fixed-derived"
app="$derived/Build/Products/Debug-iphonesimulator/CivitViewer.app"
qaRel="Library/Caches/CivitResumePromptQA-native-fixed"
runID="${1:-layout-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
out="$root/build/resume-prompt-layout-diagnostic/$runID"
scenario="dismiss"
mkdir -p "$out"
startUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sourceSHA="$(shasum -a 256 "$root/CivitViewer/ResumePromptQA.swift" "$root/CivitViewer/MediaViewer.swift" "$root/CivitViewer/TimelineLane.swift" "$root/CivitViewer/SiteSession.swift" "$root/CivitViewer/BrowsingHistory.swift" "$root/CivitViewer/CivitViewerApp.swift" | shasum -a 256 | awk '{print $1}')"

xcodebuild -quiet -project "$root/CivitViewer.xcodeproj" -scheme CivitViewer \
  -configuration Debug -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
buildSHA="$(find "$app" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
xcrun simctl install "$sim" "$app"
container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
qa="$container/$qaRel"
# This path is dedicated to simulator QA. No app support or user data is touched.
python3 -c 'import pathlib,shutil,sys; shutil.rmtree(pathlib.Path(sys.argv[1]), ignore_errors=True)' "$qa"
xcrun simctl launch --terminate-running-process "$sim" "$bundle" \
  --qa-resume-prompt --qa-resume-prompt-reset "--qa-scenario=$scenario" "--qa-run-id=$runID"
container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
qa="$container/$qaRel"

wait_for() {
  local file="$1" timeout="${2:-60}" start now
  start="$(date +%s)"
  while [[ ! -s "$file" ]]; do
    now="$(date +%s)"
    if (( now - start >= timeout )); then echo "TIMEOUT $file" >&2; return 1; fi
    sleep 0.1
  done
}
capture() {
  local imageName="$1" snapshotName="$2" snapshotSource="$3"
  xcrun simctl io "$sim" screenshot "$out/$imageName"
  cp "$qa/$snapshotSource.json" "$out/$snapshotName.json"
}

wait_for "$qa/initial.json" 60
wait_for "$qa/waiting-dismiss-$scenario.json" 20
wait_for "$qa/initial-layout-ready.json" 20
sleep 0.2
xcrun simctl io "$sim" screenshot "$out/01-initial.png"
cp "$qa/initial-layout-ready.json" "$out/01-initial.json"
printf 'ack\n' > "$qa/ack-dismiss-$scenario"
wait_for "$qa/after-dismiss.json" 30
capture "02-after-dismiss.png" "02-after-dismiss" "after-dismiss"
wait_for "$qa/waiting-next-$scenario.json" 20
printf 'ack\n' > "$qa/ack-next-$scenario"
wait_for "$qa/after-exposure.json" 30
capture "03-after-exposure.png" "03-after-exposure" "after-exposure"
wait_for "$qa/waiting-refresh-$scenario.json" 20
printf 'ack\n' > "$qa/ack-refresh-$scenario"
wait_for "$qa/waiting-capture-tab-return-1s.json" 30
sleep 1
xcrun simctl io "$sim" screenshot "$out/04-tab-return-1s.png"
printf 'ack\n' > "$qa/ack-capture-tab-return-1s"
wait_for "$qa/tab-return-1s.json" 10
cp "$qa/tab-return-1s.json" "$out/04-tab-return-1s.json"
wait_for "$qa/waiting-capture-tab-return-3s.json" 30
sleep 2
xcrun simctl io "$sim" screenshot "$out/05-tab-return-3s.png"
printf 'ack\n' > "$qa/ack-capture-tab-return-3s"
wait_for "$qa/tab-return-3s.json" 10
cp "$qa/tab-return-3s.json" "$out/05-tab-return-3s.json"

endUTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$out/receipt.json" <<EOF_RECEIPT
{
  "runID": "$runID",
  "scenario": "$scenario",
  "simulatorUDID": "$sim",
  "startUTC": "$startUTC",
  "endUTC": "$endUTC",
  "sourceSHA256": "$sourceSHA",
  "builtAppSHA256": "$buildSHA",
  "signingAllowed": false,
  "screenshotsAndJSONFromSingleRun": true
}
EOF_RECEIPT
printf 'Run ID: %s\nEvidence: %s\n' "$runID" "$out"
