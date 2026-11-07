#!/usr/bin/env python3
"""Validate the embedded Control Center extension before and after signing."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess

APP_GROUP = '3524374A2S.com.codeswhat.dilated.controls'


def validate_entitlements(entitlements):
    allowed = {'com.apple.security.app-sandbox', 'com.apple.security.application-groups',
               'com.apple.application-identifier', 'com.apple.developer.team-identifier'}
    if (set(entitlements) - allowed
            or entitlements.get('com.apple.security.app-sandbox') is not True
            or entitlements.get('com.apple.security.application-groups') != [APP_GROUP]):
        raise ValueError('Control extension has unexpected entitlements or app group')


def validate(app, signed=False):
    app = Path(app)
    try:
        host = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        host_id = host['CFBundleIdentifier']
        if host_id not in {'com.codeswhat.dilated', 'com.codeswhat.dilated.appstore'}:
            raise ValueError('Unexpected control host identity')
        plugins = app / 'Contents/PlugIns'
        extension = plugins / 'DilatedControls.appex'
        if set(plugins.iterdir()) != {extension} or extension.is_symlink():
            raise ValueError('PlugIns must contain only DilatedControls.appex')
        info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier') != host_id + '.controls'
                or info.get('CFBundleExecutable') != 'DilatedControls'
                or info.get('LSMinimumSystemVersion') != '26.0'
                or info.get('NSExtension') != {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
                or any(info.get(key) != host.get(key) for key in
                       ['CFBundleVersion', 'CFBundleShortVersionString'])):
            raise ValueError('Control extension identity, version or extension point is invalid')
        binary = extension / 'Contents/MacOS/DilatedControls'
        header = b''
        if binary.is_file() and not binary.is_symlink():
            with binary.open('rb') as executable:
                header = executable.read(8)
        if len(header) != 8 or struct.unpack('<II', header) != (0xFEEDFACF, 0x0100000C):
            raise ValueError('Control extension must have a thin arm64 executable')
        for bundle in (app, extension):
            metadata = json.loads((bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata').read_bytes())
            action = metadata['actions'].get('SetAwakeControlIntent', {})
            parameters = action.get('parameters', [])
            if (action.get('supportedModes') != 2 or action.get('isDiscoverable') is not False
                    or 'com.apple.link.systemProtocol.SetValue' not in action.get('systemProtocols', [])
                    or len(parameters) != 1 or parameters[0].get('name') != 'value'
                    or parameters[0].get('isOptional') is not False
                    or parameters[0].get('valueType') != {'primitive': {'wrapper': {'typeIdentifier': 1}}}):
                raise ValueError(f'Control intent metadata is invalid in {bundle.name}')
        if signed:
            validate_signatures(app, extension, host_id)
    except (OSError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise ValueError(f'Control extension is incomplete: {error}') from error


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, check=True, timeout=60)
    return result.stdout, result.stderr


def validate_signatures(app, extension, host_id):
    teams = []
    for bundle in (app, extension):
        command(['codesign', '--verify', '--strict', str(bundle)])
        _, description = command(['codesign', '-dv', str(bundle)])
        match = re.search(rb'^TeamIdentifier=(.+)$', description, re.MULTILINE)
        teams.append(match[1] if match else None)
    if teams[0] != teams[1]:
        raise ValueError('Control extension and host signing teams differ')
    data, _ = command(['codesign', '-d', '--entitlements', ':-', str(extension)])
    entitlements = plistlib.loads(data)
    validate_entitlements(entitlements)
    app_id = entitlements.get('com.apple.application-identifier')
    if app_id is not None and app_id != '3524374A2S.' + host_id + '.controls':
        raise ValueError('Control extension signed application identifier is invalid')
    data, _ = command(['codesign', '-d', '--entitlements', ':-', str(app)])
    if plistlib.loads(data).get('com.apple.security.application-groups') != [APP_GROUP]:
        raise ValueError('Host is missing the exact Control Center app group')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--signed', action='store_true')
    args = parser.parse_args()
    validate(args.app, signed=args.signed)
    print(f'Control extension verified: {args.app}')
