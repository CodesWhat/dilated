#!/usr/bin/env python3
"""Shared metadata helpers for the direct (build-app.sh) and Mac App Store (build-mas.sh) bundles.

stamp APP_INFO_PLIST [--display-version] [--updates 0|1] [--mas-build]
    Layers packaging/Version.plist and the source revision onto the app Info.plist, then copies
    the version keys onto the controls extension. --mas-build stamps MASBundleVersion as the
    CFBundleVersion (the Mac App Store build counter); MASBundleVersion never lands in a bundle.
    Run from the repository root.
entitlements SOURCE DESTINATION TEAM_ID BUNDLE_ID
    Writes a copy of an entitlements file with the application and team identifiers filled in.
"""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def stamp(destination, display_version, updates, mas_build=False):
    info = plistlib.loads(destination.read_bytes())
    info.update(plistlib.loads(Path('packaging/Version.plist').read_bytes()))
    mas_version = info.pop('MASBundleVersion', None)
    if mas_build:
        if not isinstance(mas_version, str) or not re.fullmatch(r'[1-9][0-9]*', mas_version):
            raise SystemExit('packaging/Version.plist needs a positive integer MASBundleVersion for the MAS build')
        info['CFBundleVersion'] = mas_version
    if display_version:
        info['DilatedDisplayVersion'] = info['CFBundleShortVersionString']
    info['DilatedSourceRevision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if updates is not None:
        info['DilatedUpdatesEnabled'] = updates == '1'
    destination.write_bytes(plistlib.dumps(info))
    extension = destination.parent / 'PlugIns/DilatedControls.appex/Contents/Info.plist'
    control_info = plistlib.loads(extension.read_bytes())
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        control_info[key] = info[key]
    extension.write_bytes(plistlib.dumps(control_info))


def entitlements(source, destination, team, bundle_id):
    values = plistlib.loads(Path(source).read_bytes())
    values['com.apple.application-identifier'] = f'{team}.{bundle_id}'
    values['com.apple.developer.team-identifier'] = team
    Path(destination).write_bytes(plistlib.dumps(values))


def main(argv):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    stamp_parser = commands.add_parser('stamp')
    stamp_parser.add_argument('info_plist', type=Path)
    stamp_parser.add_argument('--display-version', action='store_true')
    stamp_parser.add_argument('--mas-build', action='store_true')
    stamp_parser.add_argument('--updates', choices=('0', '1'), default=None)
    entitlements_parser = commands.add_parser('entitlements')
    for name in ('source', 'destination', 'team', 'bundle_id'):
        entitlements_parser.add_argument(name)
    args = parser.parse_args(argv)
    if args.command == 'stamp':
        stamp(args.info_plist, args.display_version, args.updates, args.mas_build)
    else:
        entitlements(args.source, args.destination, args.team, args.bundle_id)


if __name__ == '__main__':
    main(sys.argv[1:])
