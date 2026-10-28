"""Exercise the app's real startup LRU on the dedicated QA simulator.

Sparse fixtures test 6.3 GB of logical file sizes without downloading or
allocating 6.3 GB. This tests eviction order/budget, not video throughput.
"""
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import uuid

device = sys.argv[1]
bundle = "com.xueyj.civitviewer"
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")

def sim(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], env=env, check=check,
                          capture_output=True, text=True)

inventory = json.loads(sim("list", "devices", "available", "--json").stdout)
matches = [d for group in inventory["devices"].values() for d in group if d["udid"] == device]
assert len(matches) == 1 and matches[0]["name"] == "Civit Viewer QA", "Only use the dedicated QA simulator"
sim("terminate", device, bundle, check=False)
container = Path(sim("get_app_container", device, bundle, "data").stdout.strip())
preferences = container / "Library/Preferences" / (bundle + ".plist")
limit = plistlib.loads(preferences.read_bytes()).get("cacheLimitGB", 5) if preferences.exists() else 5
assert limit == 5, "The QA simulator must be using the normal 5 GB default"
directory = container / "Library/Caches/CivitMedia"
directory.mkdir(parents=True, exist_ok=True)
prefix = "qa-lru-" + uuid.uuid4().hex
fixtures = [directory / f"{prefix}-{i}.img" for i in range(6)]
result = {"status": "INCOMPLETE", "method": "real app startup LRU with six sparse fixtures",
          "logical_fixture_bytes": 6_300_000_000, "configured_limit_bytes": 5_000_000_000,
          "media_throughput_or_low_disk_stress_test": False}
try:
    for index, file in enumerate(fixtures):
        with file.open("xb") as stream:
            stream.truncate(1_050_000_000)
        os.utime(file, (1_000_000_000 + index, 1_000_000_000 + index))
    result["allocated_fixture_bytes"] = sum(file.stat().st_blocks * 512 for file in fixtures)
    sim("launch", device, bundle)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and fixtures[0].exists():
        time.sleep(0.25)
    remaining = [i for i, file in enumerate(fixtures) if file.exists()]
    total = sum(f.stat().st_size for f in directory.iterdir() if f.is_file())
    result.update(remaining_fixture_indices=remaining, logical_cache_bytes_after_eviction=total)
    assert remaining == [2, 3, 4, 5], "The two oldest entries should be evicted first"
    assert total <= 5_000_000_000, "The resulting cache should fit the selected budget"
    result["status"] = "PASS"
finally:
    sim("terminate", device, bundle, check=False)
    for file in fixtures:
        file.unlink(missing_ok=True)
    result["fixtures_removed"] = all(not file.exists() for file in fixtures)
    result["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    destination = Path(__file__).resolve().parents[1] / "build/cache-runtime-check.json"
    destination.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
