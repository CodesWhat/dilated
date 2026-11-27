#!/usr/bin/env python3
"""Give a SwiftPM resource bundle the Contents/ layout that codesign accepts."""
import plistlib
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def stamp_build(plist_path: Path) -> None:
    with (ROOT / 'packaging/Version.plist').open('rb') as handle:
        build = plistlib.load(handle)['MASBundleVersion']
    with plist_path.open('rb') as handle:
        info = plistlib.load(handle)
    info['CFBundleVersion'] = build
    plist_path.write_bytes(plistlib.dumps(info))


def normalize(bundle: Path, mas_build: bool = False) -> None:
    if not bundle.is_dir():
        raise SystemExit(f'normalize-resource-bundle: not a directory: {bundle}')
    contents = bundle / 'Contents'
    if (contents / 'Info.plist').is_file():
        if mas_build:
            stamp_build(contents / 'Info.plist')
        return
    resources = contents / 'Resources'
    resources.mkdir(parents=True, exist_ok=True)
    flat_plist = bundle / 'Info.plist'
    for entry in sorted(bundle.iterdir()):
        if entry.name in ('Contents', 'Info.plist'):
            continue
        shutil.move(str(entry), str(resources / entry.name))
    if flat_plist.is_file():
        shutil.move(str(flat_plist), str(contents / 'Info.plist'))
        if mas_build:
            stamp_build(contents / 'Info.plist')
        return
    with (ROOT / 'packaging/Version.plist').open('rb') as handle:
        version = plistlib.load(handle)
    info = {
        'CFBundleIdentifier': 'com.codeswhat.dilated.DilatedUI.resources',
        'CFBundleName': 'Dilated_DilatedUI',
        'CFBundlePackageType': 'BNDL',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': version['CFBundleShortVersionString'],
        'CFBundleVersion': version['MASBundleVersion'] if mas_build else version['CFBundleVersion'],
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    args = sys.argv[1:]
    mas = '--mas-build' in args
    args = [a for a in args if a != '--mas-build']
    if len(args) != 1:
        raise SystemExit('usage: normalize-resource-bundle.py <bundle-path> [--mas-build]')
    normalize(Path(args[0]), mas)
