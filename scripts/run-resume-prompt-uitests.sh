#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sim="73E8D01A-F36B-4097-934C-EAD60B1A4D0B"
bundle="com.xueyj.civitviewer"
run="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
derived="$root/build/derivedData-resume-prompt-ui-$run"
result="$root/build/resume-prompt-uitest-$run.xcresult"
logs="$root/build/resume-prompt-uitest-$run"
evidence="$root/build/resume-prompt-ui-evidence-$run"
mkdir -p "$logs" "$evidence"

python3 - "$root" "$evidence/source-before.json" <<'PY'
from pathlib import Path
import hashlib, json, sys
root=Path(sys.argv[1])
paths=set((root/'CivitViewer').rglob('*.swift'))
paths.update((root/'UITests').rglob('*.swift'))
assets=root/'CivitViewer/Assets.xcassets'
if assets.exists(): paths.update(p for p in assets.rglob('*') if p.is_file())
paths.update(root/p for p in ['CivitViewer.xcodeproj/project.pbxproj','CivitViewer.xcodeproj/xcshareddata/xcschemes/CivitViewer.xcscheme','scripts/run-resume-prompt-uitests.sh','build/playback-layout-fixture.mp4','build/viewport-vertical-fixture.mp4'])
files={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
manifest=hashlib.sha256(''.join(f'{k}:{v}\n' for k,v in sorted(files.items())).encode()).hexdigest()
Path(sys.argv[2]).write_text(json.dumps({'manifest_sha256':manifest,'source_files':files},indent=2)+'\n')
print(f'source_before_sha256={manifest}')
PY

common=(
  -project "$root/CivitViewer.xcodeproj"
  -scheme CivitViewer
  -destination "platform=iOS Simulator,id=$sim"
  -derivedDataPath "$derived"
  -parallel-testing-enabled NO
  -jobs 2
  CODE_SIGNING_ALLOWED=NO
  ONLY_ACTIVE_ARCH=YES
)

xcrun simctl bootstatus "$sim" -b > "$logs/simulator-boot.log" 2>&1

set +e
xcodebuild build-for-testing "${common[@]}" 2>&1 | tee "$logs/build.log"
build_status=${PIPESTATUS[0]}
set -e
if [[ $build_status -ne 0 ]]; then
  printf 'run_id=%s\nbuild_exit_code=%s\nlog=%s\n' "$run" "$build_status" "$logs/build.log"
  exit "$build_status"
fi

app="$derived/Build/Products/Debug-iphonesimulator/CivitViewer.app"
xcrun simctl install "$sim" "$app"
container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
fixture_dir="$container/Library/Caches/CivitResumePromptMediaQA"
mkdir -p "$fixture_dir"
cp "$root/build/playback-layout-fixture.mp4" "$fixture_dir/short.mp4"
height_fixture_dir="$container/Library/Caches/CivitViewportAuditQA"
mkdir -p "$height_fixture_dir"
cp "$root/build/viewport-vertical-fixture.mp4" "$height_fixture_dir/vertical.mp4"

args=(test-without-building "${common[@]}" -resultBundlePath "$result" -collect-test-diagnostics never)
for test_name in "$@"; do
  args+=("-only-testing:CivitViewerUITests/ResumePromptUITests/$test_name")
done
set +e
xcodebuild "${args[@]}" 2>&1 | tee "$logs/test.log"
test_status=${PIPESTATUS[0]}
set -e
xcrun simctl terminate "$sim" "$bundle" >/dev/null 2>&1 || true
# XCTest may reinstall the app while starting the runner, which can move its data container.
container="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
container_readback_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - "$root" "$logs/test.log" "$container" "$evidence" "$run" "$build_status" "$test_status" "$derived" "$container_readback_utc" <<'PY'
from pathlib import Path
import datetime, hashlib, json, re, shutil, sys
root=Path(sys.argv[1]); log_path=Path(sys.argv[2]); container=Path(sys.argv[3]); evidence=Path(sys.argv[4])
run=sys.argv[5]; build_status=int(sys.argv[6]); test_status=int(sys.argv[7])
derived=Path(sys.argv[8]); container_readback_utc=sys.argv[9]
cache = container / 'Library/Caches'
log = log_path.read_text(errors='replace')
run_ids = list(dict.fromkeys(re.findall(r'RESUME_QA_RUN_ID=([0-9A-Fa-f-]+)', log)))
folders=[]
for run_id in run_ids:
    source = cache / f'CivitResumePromptQA-UI-{run_id}'
    if source.exists():
        destination = evidence / source.name
        shutil.copytree(source, destination, dirs_exist_ok=True)
        folders.append(destination.name)
paths=set((root/'CivitViewer').rglob('*.swift'))
paths.update((root/'UITests').rglob('*.swift'))
assets=root/'CivitViewer/Assets.xcassets'
if assets.exists(): paths.update(p for p in assets.rglob('*') if p.is_file())
paths.update(root/p for p in ['CivitViewer.xcodeproj/project.pbxproj','CivitViewer.xcodeproj/xcshareddata/xcschemes/CivitViewer.xcscheme','scripts/run-resume-prompt-uitests.sh','build/playback-layout-fixture.mp4','build/viewport-vertical-fixture.mp4'])
files={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
manifest=hashlib.sha256(''.join(f'{k}:{v}\n' for k,v in sorted(files.items())).encode()).hexdigest()
before=json.loads((evidence/'source-before.json').read_text())
def tree_hash(path):
    entries=[]
    for item in sorted(p for p in path.rglob('*') if p.is_file()):
        entries.append(f'{item.relative_to(path)}:{hashlib.sha256(item.read_bytes()).hexdigest()}\n')
    return hashlib.sha256(''.join(entries).encode()).hexdigest()
app=derived/'Build/Products/Debug-iphonesimulator/CivitViewer.app'
test_bundle=derived/'Build/Products/Debug-iphonesimulator/CivitViewerUITests-Runner.app/PlugIns/CivitViewerUITests.xctest'
receipt={
 'run_id':run, 'created_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'simulator_udid':'73E8D01A-F36B-4097-934C-EAD60B1A4D0B','build_configuration':'Debug simulator unsigned',
 'build_exit_code':int(build_status),'test_exit_code':int(test_status),
 'source_manifest_before_sha256':before['manifest_sha256'],'source_manifest_after_sha256':manifest,
 'source_manifest_unchanged':before['manifest_sha256']==manifest,
 'source_files_before':before['source_files'],'source_files_after':files,
 'built_artifacts':{
   'app_bundle_path':str(app), 'app_bundle_sha256':tree_hash(app),
   'app_executable_sha256':hashlib.sha256((app/'CivitViewer').read_bytes()).hexdigest(),
   'app_debug_dylib_sha256':hashlib.sha256((app/'CivitViewer.debug.dylib').read_bytes()).hexdigest(),
   'ui_test_bundle_path':str(test_bundle), 'ui_test_bundle_sha256':tree_hash(test_bundle),
   'ui_test_executable_sha256':hashlib.sha256((test_bundle/'CivitViewerUITests').read_bytes()).hexdigest()
 },
 'qa_run_ids':run_ids,'copied_qa_fixture_folders':folders,
 'post_test_app_container':str(container),'post_test_app_container_readback_utc':container_readback_utc,
 'fixture':'build/playback-layout-fixture.mp4 copied to CivitResumePromptMediaQA/short.mp4; local H.264 30-second video-only sample; no audio track',
 'result_bundle':str(root/f'build/resume-prompt-uitest-{run}.xcresult'),
 'logs':{'build':str(root/f'build/resume-prompt-uitest-{run}/build.log'),'test':str(root/f'build/resume-prompt-uitest-{run}/test.log')},
 'scope':'Simulator UI XCTest only; gestures use XCTest tap/doubleTap/swipe on native controls; no phone install, credentials, site requests, Mac UI, or audio changes.'
}
(evidence/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'evidence':str(evidence),'run_ids':run_ids,'source_manifest_sha256':manifest,'test_exit_code':int(test_status)}))
PY
printf 'run_id=%s\nresult=%s\nlogs=%s\nevidence=%s\nexit_code=%s\n' "$run" "$result" "$logs" "$evidence" "$test_status"
exit "$test_status"
