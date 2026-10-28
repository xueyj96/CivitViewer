#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo '用法: bash scripts/install-phone.sh <已配对的设备名称或标识符>' >&2
  exit 2
fi
device_target="$1"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p "$task_root/build"
build_log="$task_root/build/phone-install-build.log"
if ! xcodebuild -project "$task_root/CivitViewer.xcodeproj" -scheme CivitViewer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$task_root/build/Phone" -allowProvisioningUpdates build > "$build_log" 2>&1; then
  rg 'error:|BUILD FAILED' "$build_log" >&2 || true
  echo "构建失败，日志: $build_log" >&2
  exit 1
fi
app_path="$task_root/build/Phone/Build/Products/Debug-iphoneos/CivitViewer.app"
codesign --verify --deep --strict "$app_path"
python3 - "$app_path/embedded.mobileprovision" <<'PY'
import datetime, plistlib, subprocess, sys
result = subprocess.run(['security', 'cms', '-D', '-i', sys.argv[1]], check=True, capture_output=True)
profile = plistlib.loads(result.stdout)
expires = profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if expires <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('描述文件已过期；请先在 Xcode 刷新签名。')
print('本次签名到期时间（UTC）:', expires.isoformat())
PY
xcrun devicectl device install app --device "$device_target" "$app_path"
xcrun devicectl device info apps --device "$device_target" --filter 'bundleIdentifier == "com.xueyj.civitviewer"'
