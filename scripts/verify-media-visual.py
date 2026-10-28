#!/usr/bin/env python3
"""Install only on the named simulator; capture native controlled-media pixels.

No site API, credentials, phone, UI gesture injection or user-data deletion.
Pass a simulator UDID. Requires a successful build/Simulator product.
"""
from pathlib import Path
import subprocess, json, shutil, time, sys, plistlib, hashlib, datetime, uuid, os

root = Path(__file__).resolve().parents[1]
sim = sys.argv[1]
product = Path(os.environ.get('CIVIT_MEDIA_QA_PRODUCT', str(root / 'build/Simulator/Build/Products/Debug-iphonesimulator/CivitViewer.app')))
with (product / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
expected_build = str(info['CFBundleVersion'])
run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(uuid.uuid4())
output = root / f'build/ui{expected_build}-media-visual' / run_id
output.mkdir(parents=True, exist_ok=False)
def manifest(paths, base):
    rows = [{'path': str(path.relative_to(base)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in sorted(paths) if path.is_file() and path.name != '.DS_Store']
    return {'files': rows, 'sha256': hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}
source_manifest = manifest([*(root / 'CivitViewer').rglob('*'), root / 'CivitViewer.xcodeproj/project.pbxproj'], root)
receipt = {'run_id': run_id, 'started_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'version': info['CFBundleShortVersionString'], 'build': expected_build,
           'source': source_manifest, 'built_app': manifest(product.rglob('*'), product),
           'scope': 'Local synthetic patterns; production native renderer; simulator only; no site requests'}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
def run(args, **kwargs):
    return subprocess.run(['xcrun', 'simctl', *args], check=True, capture_output=True, text=True, timeout=35, **kwargs)
run(['install', sim, str(product)])
container = Path(run(['get_app_container', sim, 'com.xueyj.civitviewer', 'data']).stdout.strip())
fixtures = container / 'Library/Caches/CivitMediaFormatQA'
fixtures.mkdir(parents=True, exist_ok=True)
for fixture_name, target in [('animated.gif', 'animated.jpeg'), ('animated.webp', 'animated.webp'), ('short.mp4', 'short.mp4')]:
    shutil.copy2(root / 'Tests/Fixtures' / fixture_name, fixtures / target)
# A single source frame is a valid controlled static PNG; no user image involved.
subprocess.run(['sips', '-s', 'format', 'png', str(root / 'Tests/Fixtures/animated.gif'), '--out', str(fixtures / 'static.png')],
               check=True, capture_output=True, timeout=15)
report = fixtures / 'readback.json'
rows = []
cases = sys.argv[2:] or ['gif', 'webp', 'static', 'video-as-image', 'gif-as-video', 'poster', 'autoplay-off', 'inactive']
for case in cases:
    report.unlink(missing_ok=True)
    started = time.monotonic()
    run(['launch', '--terminate-running-process', sim, 'com.xueyj.civitviewer', '--qa-media-format', case])
    deadline = time.monotonic() + 12
    value = None
    while time.monotonic() < deadline:
        try:
            candidate = json.loads(report.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.15); continue
        if candidate.get('build') != expected_build or candidate.get('case') != case:
            time.sleep(.15); continue
        bitmaps, videos = candidate.get('bitmaps', []), candidate.get('videos', [])
        ready = (case == 'poster' and time.monotonic() - started > 3)
        if case in ['gif', 'webp', 'gif-as-video']:
            ready = any(b.get('animating') and b.get('frames', 0) > 1 for b in bitmaps)
        elif case == 'video-as-image':
            ready = any(v.get('readyForDisplay') and v.get('rate', 0) > 0 for v in videos)
        elif case == 'static':
            ready = bool(bitmaps) and not any(b.get('animating') for b in bitmaps)
        elif case == 'autoplay-off':
            ready = any(b.get('frames', 0) > 1 and not b.get('animating') for b in bitmaps)
        elif case == 'inactive':
            ready = time.monotonic() - started > 4.3 and bool(bitmaps) and all(b.get('frames') == 0 and not b.get('animating') for b in bitmaps)
        if ready:
            value = candidate; break
        time.sleep(.15)
    first = output / (case + '-a.png')
    second = output / (case + '-b.png')
    run(['io', sim, 'screenshot', str(first)])
    time.sleep(.33)
    run(['io', sim, 'screenshot', str(second)])
    third = output / (case + '-c.png')
    time.sleep(.1)
    run(['io', sim, 'screenshot', str(third)])
    row = {'run_id': run_id, 'case': case, 'native_component_state_pass': value is not None, 'readback': value,
           'screenshots': [str(first.relative_to(root)), str(second.relative_to(root)), str(third.relative_to(root))],
           'pixel_acceptance': 'PENDING_SEPARATE_PIXEL_INSPECTION'}
    rows.append(row)
    print(json.dumps({'case': case, 'component_state': value is not None}), flush=True)
    (output / ('native-matrix.json' if len(cases) == 8 else 'native-matrix-subset.json')).write_text(json.dumps(rows, indent=2) + '\n')
run(['terminate', sim, 'com.xueyj.civitviewer'])
receipt.update({'completed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'source_unchanged_during_capture': source_manifest == manifest([*(root / 'CivitViewer').rglob('*'), root / 'CivitViewer.xcodeproj/project.pbxproj'], root),
                'case_count': len(rows), 'native_component_state_pass': all(row['native_component_state_pass'] for row in rows)})
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'evidence': str(output), 'source_unchanged': receipt['source_unchanged_during_capture']}), flush=True)
raise SystemExit(not (receipt['native_component_state_pass'] and receipt['source_unchanged_during_capture']))
