#!/usr/bin/env python3
"""Package a device Release app for recipient re-signing without personal profiles."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile

MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}

def sha(data): return hashlib.sha256(data).hexdigest()
def file_hashes(root):
    return {str(p.relative_to(root)): sha(p.read_bytes())
            for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()}
def command(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed for {Path(args[-1]).name} (exit {result.returncode})')
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    source = args.app.resolve(strict=True)
    if source.suffix != '.app' or not source.is_dir():
        raise ValueError('--app must select a device Release .app bundle')
    info = plistlib.loads((source/'Info.plist').read_bytes())
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Simulator apps cannot be packaged for a physical iPhone')
    if (source/'CivitViewer.debug.dylib').exists():
        raise ValueError('Select the Release product, not the Debug product')
    load_commands = command('xcrun','otool','-l',str(source/info['CFBundleExecutable'])).stdout
    if b'__llvm_prf' in load_commands or b'__llvm_cov' in load_commands:
        raise ValueError('Disable code coverage when building the public Release product')
    original = file_hashes(source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists() or args.report.exists():
        raise FileExistsError('Inspect existing output before creating another package')
    with tempfile.TemporaryDirectory(prefix='civit-release-package-') as directory:
        root = Path(directory)
        app = root/'Payload'/source.name
        shutil.copytree(source, app, symlinks=True)
        for path in list(app.rglob('*')):
            if path.is_symlink():
                if not path.resolve().is_relative_to(app):
                    raise ValueError('An application symlink escapes the bundle')
            elif path.is_file() and path.suffix.lower() in {'.mobileprovision', '.provisionprofile'}:
                path.unlink()
            elif path.is_file() and path.suffix.lower() in {'.p12', '.pfx', '.key', '.pem'}:
                raise ValueError('Unexpected signing material in application resources')
        for path in sorted(app.rglob('_CodeSignature'), key=lambda p: len(p.parts), reverse=True):
            if path.is_dir() and not path.is_symlink(): shutil.rmtree(path)
        binaries = []
        for path in sorted(app.rglob('*')):
            if not path.is_file() or path.is_symlink(): continue
            with path.open('rb') as file: magic = file.read(4)
            if magic in MACHO: binaries.append(path)
        executable = app/info['CFBundleExecutable']
        if executable not in binaries: raise ValueError('Main Mach-O executable is missing')
        for path in binaries:
            # Remove any old CMS signature/entitlements instead of preserving identity.
            signed = subprocess.run(['codesign','-d',str(path)], capture_output=True)
            if signed.returncode == 0: command('codesign','--remove-signature',str(path))
            command('codesign','--force','--sign','-','--timestamp=none',str(path))
        for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
            command('codesign','--force','--sign','-','--timestamp=none',str(framework))
        # The local ad-hoc checksum is not an Apple distribution authorization.
        # Recipients must replace it with their own valid signature using a sideload tool.
        command('codesign','--force','--sign','-','--timestamp=none',str(app))
        command('codesign','--verify','--deep','--strict',str(app))
        for path in binaries:
            result = command('codesign','-dvv',str(path))
            details = (result.stdout+result.stderr).decode(errors='replace')
            if 'Signature=adhoc' not in details or 'Authority=' in details:
                raise ValueError('A non-ad-hoc certificate signature remains in the package')
            if any(line.startswith('TeamIdentifier=') and line != 'TeamIdentifier=not set'
                   for line in details.splitlines()):
                raise ValueError('A personal signing team remains in the package')
            result = command('codesign','-d','--entitlements',':-',str(path))
            if result.stdout and plistlib.loads(result.stdout):
                raise ValueError('Unexpected entitlements remain before recipient re-signing')
        forbidden = [p for p in app.rglob('*') if p.is_file() and p.suffix.lower()
                     in {'.mobileprovision','.provisionprofile','.p12','.pfx','.key','.pem'}]
        if forbidden: raise ValueError('Personal provisioning or signing material remains')
        expected = file_hashes(app)
        with zipfile.ZipFile(args.output, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted((root/'Payload').rglob('*')):
                name = path.relative_to(root).as_posix()
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(path).encode())
                else: archive.write(path, name)
        with zipfile.ZipFile(args.output) as archive:
            if archive.testzip() is not None: raise ValueError('IPA CRC verification failed')
            if any(not n.startswith('Payload/'+source.name+'/') for n in archive.namelist()):
                raise ValueError('Unexpected archive root')
            archived = {name.removeprefix('Payload/'+source.name+'/'):sha(archive.read(name))
                        for name in archive.namelist() if not name.endswith('/') and
                        not stat.S_ISLNK(archive.getinfo(name).external_attr >> 16)}
            if archived != expected: raise ValueError('Packaged files differ from the verified app')
        if file_hashes(source) != original: raise ValueError('Original input app was modified')
        report = {'bundle_identifier':info['CFBundleIdentifier'],
                  'version':info['CFBundleShortVersionString'], 'build':info['CFBundleVersion'],
                  'minimum_ios':info.get('MinimumOSVersion'), 'platforms':info['CFBundleSupportedPlatforms'],
                  'ipa_filename':args.output.name, 'ipa_bytes':args.output.stat().st_size,
                  'ipa_sha256':sha(args.output.read_bytes()), 'packaged_regular_files':len(expected),
                  'macho_binaries_checked':len(binaries), 'personal_provisioning_profiles':0,
                  'personal_certificate_signatures':0, 'personal_signing_entitlements':0,
                  'local_checksum_signatures':'ad-hoc, must be replaced by recipient signing',
                  'deep_strict_codesign_passed':True, 'ipa_crc_and_file_hashes_passed':True,
                  'main_executable_has_no_coverage_sections':True,
                  'original_input_app_unchanged':True, 'recipient_resigning_required':True,
                  'device_install_after_recipient_resigning':'NOT_TESTED'}
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))

if __name__ == '__main__': main()
