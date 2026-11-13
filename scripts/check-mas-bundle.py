#!/usr/bin/env python3
"""Fail on anything in a built Mac App Store Dilated.app that App Review would reject.

Usage: python3 -I scripts/check-mas-bundle.py PATH/Dilated.app [--bundle-id ID] [--entitlements FILE]

Entitlements are read from the signature with codesign unless --entitlements gives a plist.
Exit 0 when the bundle is clean, 1 with one line per failure otherwise.
"""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

_spec = importlib.util.spec_from_file_location('controls_bundle', Path(__file__).with_name('controls-bundle.py'))
controls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(controls)

BUNDLE_ID = 'com.codeswhat.dilated.appstore'
MAIN_EXECUTABLE = 'DilatedApp'
ENTITLEMENT_ALLOWLIST = frozenset({
    'com.apple.security.app-sandbox',
    'com.apple.security.application-groups',
    'com.apple.security.network.client',
    'com.apple.security.personal-information.location',
    'com.apple.security.device.bluetooth',
    'com.apple.security.device.usb',
    'com.apple.security.files.user-selected.read-only',
    'com.apple.security.files.user-selected.read-write',
    'com.apple.security.files.bookmarks.app-scope',
    'com.apple.security.files.downloads.read-only',
    'com.apple.application-identifier',
    'com.apple.developer.team-identifier',
})
CPU_ARM64 = 0x0100000C
MACHO_THIN = {0xFEEDFACE, 0xFEEDFACF}
MACHO_FAT = {0xCAFEBABE, 0xCAFEBABF}


def macho_architectures(path):
    """CPU types of a Mach-O file, or None when the file is not Mach-O."""
    with path.open('rb') as file:
        head = file.read(4096)
    if len(head) < 8:
        return None
    for order in ('>', '<'):
        (magic,) = struct.unpack(order + 'I', head[:4])
        if magic in MACHO_FAT and order == '>':
            count = struct.unpack('>I', head[4:8])[0]
            size = 32 if magic == 0xCAFEBABF else 20
            if count > 32 or len(head) < 8 + count * size:
                return None
            return [struct.unpack('>I', head[8 + i * size:12 + i * size])[0] for i in range(count)]
        if magic in MACHO_THIN:
            return [struct.unpack(order + 'I', head[4:8])[0]]
    return None


def walk_keys(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_keys(child)


def load_plist(path):
    with path.open('rb') as file:
        return plistlib.load(file)


def read_signed_entitlements(app):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                            capture_output=True, timeout=60)
    if result.returncode != 0 or not result.stdout.strip():
        raise ValueError(f'codesign could not read entitlements: {result.stderr.decode(errors="replace").strip()}')
    return plistlib.loads(result.stdout)


def check_entitlements(entitlements, failures):
    for key in sorted(walk_keys(entitlements)):
        if 'temporary-exception' in key:
            failures.append(f'entitlement {key}: temporary-exception entitlements are not allowed')
        elif key not in ENTITLEMENT_ALLOWLIST:
            failures.append(f'entitlement {key}: not in the MAS allowlist')
    if entitlements.get('com.apple.security.app-sandbox') is not True:
        failures.append('entitlement com.apple.security.app-sandbox must be true')
    if entitlements.get('com.apple.security.application-groups') != [controls.APP_GROUP]:
        failures.append('entitlement app group must be the exact Dilated controls group')


def is_daemon_plist(relative, info):
    if 'LaunchDaemons' in relative.parts or 'LaunchAgents' in relative.parts:
        return True
    return isinstance(info, dict) and 'Label' in info and any(
        key in info for key in ('ProgramArguments', 'BundleProgram', 'Program'))


def check_bundle(app, bundle_id, entitlements):
    """Return a list of human-readable failures for the app at `app`."""
    failures = []
    app = Path(app)
    try:
        info = load_plist(app / 'Contents/Info.plist')
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return [f'Contents/Info.plist is missing or unreadable: {error}']

    if info.get('CFBundleIdentifier') != bundle_id:
        failures.append(f'CFBundleIdentifier is {info.get("CFBundleIdentifier")!r}, expected {bundle_id!r}')
    if info.get('DilatedDisplayVersion', info.get('CFBundleShortVersionString')) != info.get('CFBundleShortVersionString'):
        failures.append('MAS display version must match CFBundleShortVersionString')
    if not info.get('LSApplicationCategoryType'):
        failures.append('LSApplicationCategoryType is missing from Info.plist')
    if info.get('CFBundleExecutable') != MAIN_EXECUTABLE:
        failures.append(f'CFBundleExecutable is {info.get("CFBundleExecutable")!r}, expected {MAIN_EXECUTABLE!r}')
    for key in sorted(walk_keys(info)):
        if key.startswith('SU'):
            failures.append(f'Info.plist key {key}: Sparkle SU* keys are not allowed')
        if 'temporary-exception' in key:
            failures.append(f'Info.plist key {key}: temporary-exception keys are not allowed')

    main = app / 'Contents/MacOS' / MAIN_EXECUTABLE
    main_arches = macho_architectures(main) if main.is_file() else None
    if main_arches is None:
        failures.append(f'Contents/MacOS/{MAIN_EXECUTABLE} is missing or is not a Mach-O executable')
    elif main_arches != [CPU_ARM64]:
        failures.append(f'Contents/MacOS/{MAIN_EXECUTABLE}: architectures {[hex(a) for a in main_arches]}, '
                        'expected arm64 only')

    control_executable = None
    try:
        controls.validate(app)
        control_executable = app / 'Contents/PlugIns/DilatedControls.appex/Contents/MacOS/DilatedControls'
    except ValueError as error:
        failures.append(f'Control extension: {error}')

    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app)
        if not path.is_symlink() and path.is_file() and not path.stat().st_mode & 0o004:
            failures.append(f'{relative}: bundled files must be readable by all users')
        if any('sparkle' in part.lower() for part in relative.parts):
            failures.append(f'{relative}: Sparkle must not be in the bundle')
        if path.is_symlink() or not path.is_file() or path == main:
            continue
        arches = macho_architectures(path)
        with path.open('rb') as file:
            shebang = file.read(2) == b'#!'
        if path != control_executable and (arches is not None or shebang or path.stat().st_mode & 0o111):
            failures.append(f'{relative}: embedded executable (only Contents/MacOS/{MAIN_EXECUTABLE} may be one)')
        if arches is not None and arches != [CPU_ARM64]:
            failures.append(f'{relative}: architectures {[hex(a) for a in arches]}, expected arm64 only')
        if path.suffix == '.plist':
            try:
                inner = load_plist(path)
            except (OSError, plistlib.InvalidFileException, ValueError):
                inner = None
            if is_daemon_plist(relative, inner):
                failures.append(f'{relative}: daemon or LaunchAgent plist must not ship in the app')

    check_entitlements(entitlements, failures)
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('app', type=Path)
    parser.add_argument('--bundle-id', default=BUNDLE_ID)
    parser.add_argument('--entitlements', type=Path, help='plist to check instead of the signed entitlements')
    args = parser.parse_args(argv)
    try:
        if args.entitlements:
            entitlements = load_plist(args.entitlements)
        else:
            entitlements = read_signed_entitlements(args.app)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f'check-mas-bundle: FAIL: {error}', file=sys.stderr)
        return 1
    failures = check_bundle(args.app, args.bundle_id, entitlements)
    for failure in failures:
        print(f'check-mas-bundle: FAIL: {failure}', file=sys.stderr)
    if failures:
        print(f'check-mas-bundle: {len(failures)} failure(s) in {args.app}', file=sys.stderr)
        return 1
    print(f'check-mas-bundle: OK {args.app} ({args.bundle_id})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
