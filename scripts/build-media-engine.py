#!/usr/bin/env python3
"""Build a replaceable dynamic iOS framework from pinned FFmpeg and our C API.

FFmpeg is never executed as a subprocess on iOS. All app-facing media operations
are local-file C calls. Build the pinned libraries with build-ffmpeg-ios.py first.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor'
ENGINE = VENDOR / 'CivitMediaEngine'
OUTPUT = ROOT / 'build' / 'media-engine47'

def run(args):
    subprocess.run([str(x) for x in args], check=True)

def build(platform):
    simulator = platform == 'ios-simulator-arm64'
    sdk = 'iphonesimulator' if simulator else 'iphoneos'
    target = 'arm64-apple-ios17.0-simulator' if simulator else 'arm64-apple-ios17.0'
    sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    ffmpeg = VENDOR / 'FFmpeg' / 'build' / platform
    framework = OUTPUT / platform / 'CivitMediaEngine.framework'
    framework.mkdir(parents=True, exist_ok=True)
    (framework / 'Headers').mkdir(exist_ok=True)
    (framework / 'Modules').mkdir(exist_ok=True)
    shutil.copy2(ENGINE / 'CivitMediaEngine.h', framework / 'Headers')
    (framework / 'Modules' / 'module.modulemap').write_text('framework module CivitMediaEngine {\n  umbrella header "CivitMediaEngine.h"\n  export *\n}\n')
    exports = OUTPUT / 'exports.txt'
    exports.write_text(''.join('_' + x + '\n' for x in ('cvm_job_create', 'cvm_job_cancel', 'cvm_job_destroy', 'cvm_job_progress', 'cvm_probe', 'cvm_convert', 'cvm_engine_version')))
    libraries = [ffmpeg / 'lib' / ('lib' + name + '.a') for name in ('avformat', 'avcodec', 'swscale', 'swresample', 'avutil')]
    if not all(x.is_file() for x in libraries):
        raise SystemExit(f'Missing pinned FFmpeg libraries for {platform}')
    command = ['xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', sdk_path,
        '-std=c11', '-O2', '-fPIC', '-dynamiclib', '-Wall', '-Wextra', '-Wno-unused-parameter',
        '-I', ffmpeg / 'include', ENGINE / 'CivitMediaEngine.c',
        '-install_name', '@rpath/CivitMediaEngine.framework/CivitMediaEngine',
        '-Wl,-exported_symbols_list,' + str(exports), '-Wl,-dead_strip', '-o', framework / 'CivitMediaEngine']
    for library in libraries:
        command.append('-Wl,-force_load,' + str(library))
    for name in ('Foundation', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'VideoToolbox', 'AudioToolbox'):
        command += ['-framework', name]
    command += ['-lm', '-lpthread']
    run(command)
    info = dict(CFBundleExecutable='CivitMediaEngine', CFBundleIdentifier='com.xueyj.CivitMediaEngine',
        CFBundleName='CivitMediaEngine', CFBundlePackageType='FMWK', CFBundleShortVersionString='1.0',
        CFBundleVersion='1', MinimumOSVersion='17.0', CFBundleSupportedPlatforms=['iPhoneSimulator' if simulator else 'iPhoneOS'])
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    run(['codesign', '--force', '--sign', '-', framework])
    return framework

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['ios-arm64', 'ios-simulator-arm64'], action='append')
    args = parser.parse_args()
    selected = args.platform or ['ios-arm64', 'ios-simulator-arm64']
    OUTPUT.mkdir(parents=True, exist_ok=True)
    frameworks = [build(platform) for platform in selected]
    destination = VENDOR / 'CivitMediaEngine.xcframework'
    # Replace only our known, reproducible artifact after all selected builds pass.
    if destination.exists(): shutil.rmtree(destination)
    command = ['xcodebuild', '-create-xcframework']
    for framework in frameworks: command += ['-framework', framework]
    run(command + ['-output', destination])
    manifest = {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
        for base in [ENGINE, destination] for file in sorted(base.rglob('*')) if file.is_file()}
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__': main()
