#!/usr/bin/env python3
"""Bounded native footer geometry capture on an explicitly named simulator.

Uses only the existing local synthetic playback QA route. No site requests,
physical phone operations, settings changes, or user-media reads.
"""
from pathlib import Path
import datetime
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import time
import uuid
import argparse

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('sim')
parser.add_argument('size', choices=('main', 'small'))
parser.add_argument('--case', choices=('portrait-seeking', 'landscape-seeking', 'landscape-buffering'))
parser.add_argument('--skip-install', action='store_true', help='Use an already-installed matching build; never installs.')
options = parser.parse_args()
sim, size = options.sim, options.size
assert size in ('main', 'small')
product = root / 'build/Simulator/Build/Products/Debug-iphonesimulator/CivitViewer.app'
info = plistlib.loads((product / 'Info.plist').read_bytes())
expected_build = str(info['CFBundleVersion'])
source = json.loads((root / f'build/ui{expected_build}-source-manifest.json').read_text())
run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(uuid.uuid4())
output = root / f'build/ui{expected_build}-playback-layout' / (size + '-' + run_id)
output.mkdir(parents=True, exist_ok=False)

def run(args):
    return subprocess.run(['xcrun', 'simctl', *args], check=True, capture_output=True, text=True, timeout=35)

if options.skip_install:
    installed = Path(run(['get_app_container', sim, info['CFBundleIdentifier'], 'app']).stdout.strip())
    installed_info = plistlib.loads((installed / 'Info.plist').read_bytes())
    installed_hash = hashlib.sha256((installed / 'CivitViewer').read_bytes()).hexdigest()
    product_hash = hashlib.sha256((product / 'CivitViewer').read_bytes()).hexdigest()
    if str(installed_info.get('CFBundleVersion')) != expected_build or installed_hash != product_hash:
        raise SystemExit('installed app does not match the local QA product; --skip-install refused')
else:
    run(['install', sim, str(product)])
container = Path(run(['get_app_container', sim, info['CFBundleIdentifier'], 'data']).stdout.strip())
cache = container / 'Library/Caches/CivitPlaybackLayoutQA'
cache.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / 'build/playback-layout-fixture.mp4', cache / 'fixture.mp4')
report = cache / 'layout-readback.json'
cases = [('portrait-seeking', 'seeking', False), ('landscape-seeking', 'seeking', True)] if size == 'main' else [('landscape-buffering', 'buffering', True)]
if options.case:
    cases = [case for case in cases if case[0] == options.case]
    if not cases:
        raise SystemExit(f'{options.case} is not a case for --size {size}')
rows = []
receipt = {'run_id': run_id, 'source_sha256': source['source_sha256'], 'build': expected_build,
           'started_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'case_selection': [case[0] for case in cases], 'install_skipped': options.skip_install,
           'scope': 'Existing production native MediaDeck/VideoSurface/SeekTrackView in a TabView; local synthetic video; simulator only'}
for name, variant, landscape in cases:
    report.unlink(missing_ok=True)
    args = ['launch', '--terminate-running-process', sim, info['CFBundleIdentifier'], '--qa-playback-layout', '--qa-playback-state', variant]
    if landscape:
        args.append('--qa-layout-landscape')
    run(args)
    deadline = time.monotonic() + 15
    value = None
    while time.monotonic() < deadline:
        try:
            candidate = json.loads(report.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.15)
            continue
        if str(candidate.get('build')) == expected_build and candidate.get('variant') == variant and candidate.get('requestedLandscape') == landscape:
            value = candidate
            break
        time.sleep(.15)
    assert value is not None, name + ': native readback unavailable'
    run(['io', sim, 'screenshot', str(output / (name + '.png'))])
    tracks = value.get('tracks', [])
    frames = value.get('layoutFrames', {})
    actions, progress, viewport = (frames.get(key, {}) for key in ('actions', 'progress', 'viewport'))
    assert len(tracks) == 1 and actions and progress and viewport, name + ': missing native geometry'
    track = tracks[0]
    footer = progress['y'] + progress['height'] - actions['y'] + 4
    available = viewport['height'] - max(120, footer + 8) - 110
    passed = (value.get('geometryConverged') and value.get('landscape') == landscape
              and value.get('actionsProgressSeparated') and value.get('progressWithinContentViewport')
              and track.get('isUIControl') and not track.get('isOpaque')
              and track.get('backgroundAlpha') == 0 and track.get('height', 0) >= 44 and available > 0)
    row = {'case': name, 'readback': value, 'geometry_pass': bool(passed), 'main_gesture_available_height': available,
           'pixel_acceptance': 'PENDING_ROOT_INSPECTION'}
    rows.append(row)
    (output / (name + '.json')).write_text(json.dumps(row, indent=2) + '\n')
    print(json.dumps({'case': size + '-' + name, 'geometry_pass': bool(passed), 'main_gesture_height': available}), flush=True)
run(['terminate', sim, info['CFBundleIdentifier']])
current = {path: hashlib.sha256((root / path).read_bytes()).hexdigest() for path in source['files']}
receipt.update({'completed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'source_matches_final': current == source['files'],
                'geometry_cases': len(rows), 'geometry_pass': all(row['geometry_pass'] for row in rows)})
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'evidence': str(output)}), flush=True)
raise SystemExit(not (receipt['geometry_pass'] and receipt['source_matches_final']))
