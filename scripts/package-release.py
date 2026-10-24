#!/usr/bin/env python3
"""Build and notarize a ZIP and a DMG installer from a clean, exact release tag without launching the app."""
# Adapted from Mouthtype, Scott Benson, under the Dilated MIT author grant.
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def run(args, *, cwd=None, timeout=60, log=None):
    if log:
        with Path(log).open('w') as output:
            subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=timeout)
        return ''
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stdout}{result.stderr}')
    return result.stdout


def release_metadata(root):
    with (root / 'packaging/Version.plist').open('rb') as file:
        metadata = plistlib.load(file)
    version = metadata.get('DilatedDisplayVersion', '')
    number = r'(?:0|[1-9][0-9]*)'
    if not re.fullmatch(rf'{number}\.{number}\.{number}(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?', version):
        raise RuntimeError('Invalid release display version')
    if metadata.get('CFBundleShortVersionString') != version.split('-')[0]:
        raise RuntimeError('Marketing version must match the release version')
    if not re.fullmatch(r'[1-9][0-9]*', metadata.get('CFBundleVersion', '')):
        raise RuntimeError('Build number must be a positive integer')
    return metadata


def verify_source(root, version, candidate=False):
    if run(['git', 'status', '--porcelain'], cwd=root).strip():
        raise RuntimeError('Release source must be clean, including untracked files')
    head = run(['git', 'rev-parse', 'HEAD'], cwd=root).strip()
    if candidate:
        return head
    tagged = run(['git', 'rev-parse', f'refs/tags/v{version}^{{commit}}'], cwd=root).strip()
    if head != tagged:
        raise RuntimeError('HEAD must match the exact release tag')
    return head


def create_output(base, version):
    output = base / version
    output.mkdir(parents=True, exist_ok=False)
    return output


def validate_helper_bundle(app):
    name = 'com.codeswhat.dilated.helper'
    with (app / f'Contents/Library/LaunchDaemons/{name}.plist').open('rb') as file:
        daemon = plistlib.load(file)
    expected = {'Label': name, 'BundleProgram': 'Contents/MacOS/dilated-helper',
                'MachServices': {name: True}, 'UserName': 'root', 'RunAtLoad': True, 'KeepAlive': True}
    if any(daemon.get(key) != value for key, value in expected.items()):
        raise RuntimeError('The bundled helper has an invalid LaunchDaemon configuration')
    executable = app / expected['BundleProgram']
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError('The bundled helper executable is missing or not executable')
    return executable


def validate_automation_bundle(app):
    try:
        with (app / 'Contents/Info.plist').open('rb') as file:
            info = plistlib.load(file)
        resources = app / 'Contents/Resources'
        metadata = json.loads((resources / 'Metadata.appintents/extract.actionsdata').read_bytes())
        dictionary = ET.parse(resources / 'Dilated.sdef')
        expected = {'StartAwakeIntent', 'StopAwakeIntent', 'AwakeStatusIntent', 'SetClosedLidIntent'}
        actions = metadata['actions']
        if (not info.get('NSAppleScriptEnabled') or info.get('OSAScriptingDefinition') != 'Dilated.sdef'
                or set(actions) != expected or not metadata.get('autoShortcutProviderMangledName')
                or {item['actionIdentifier'] for item in metadata['autoShortcuts']} != expected
                or any(action.get('supportedModes') != 1 or not action.get('isDiscoverable')
                       for action in actions.values())):
            raise ValueError('Invalid intent or scripting configuration')
        codes = {'amph' + code for code in ['cAct', 'cmOn', 'cOff', 'STRm', 'DSOK', 'AWDS', 'PTDS',
                                          'CDMK', 'ECDM', 'DCDM', 'SisT', 'TrEn', 'EnTr', 'DsTr']}
        commands = dictionary.findall('./suite/command')
        if (len(commands) != len(codes) or {item.get('code') for item in commands} != codes
                or any(item.find('cocoa') is None
                       or item.find('cocoa').get('class') != 'DilatedScriptCommand' for item in commands)):
            raise ValueError('Invalid scripting dictionary')
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError) as error:
        raise RuntimeError(f'The app has missing or invalid automation metadata: {error}') from error


def verify_requirement(executable, requirement):
    run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(executable)])


def verify_app(app, output, label):
    helper = validate_helper_bundle(app)
    validate_automation_bundle(app)
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    for executable, identifier in ((app, 'com.codeswhat.dilated'), (helper, 'com.codeswhat.dilated.helper')):
        requirement = f'identifier "{identifier}" and anchor apple generic and certificate leaf[subject.OU] = "3524374A2S"'
        verify_requirement(executable, requirement)
    run(['xcrun', 'stapler', 'validate', str(app)], log=output / f'{label}-staple.log')
    run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], log=output / f'{label}-gatekeeper.log')


def dmg_identity(codesign_output):
    for line in codesign_output.splitlines():
        if line.startswith('Authority=Developer ID Application:'):
            return line.split('=', 1)[1]
    raise RuntimeError('A CodesWhat Developer ID signature is required')


def create_update_archive(app, archive):
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], timeout=180)


ASC_DIRECTORY = Path.home() / '.appstoreconnect'


def read_asc_config(config):
    """Parse KEY=VALUE lines (optionally prefixed with export) without evaluating the file."""
    values = {}
    for line in Path(config).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('export '):
            line = line[len('export '):].strip()
        name, separator, value = line.partition('=')
        if separator:
            values[name.strip()] = value.strip().strip('"\'')
    return values


def api_key_auth(directory=ASC_DIRECTORY):
    """Return notarytool API-key arguments, or None when no key file is stored. Values are never printed."""
    directory = Path(directory)
    config = directory / 'config.env'
    if not config.is_file():
        return None
    values = read_asc_config(config)
    key_id, issuer = values.get('ASC_KEY_ID'), values.get('ASC_ISSUER_ID')
    if not key_id or not issuer:
        return None
    key = directory / 'private_keys' / f'AuthKey_{key_id}.p8'
    if not key.is_file():
        return None
    return ['--key', str(key), '--key-id', key_id, '--issuer', issuer]


def notary_auth(profile=None, directory=ASC_DIRECTORY):
    """An explicit Keychain profile overrides; otherwise the App Store Connect API key is the default."""
    if profile:
        return ['--keychain-profile', profile]
    auth = api_key_auth(directory)
    if auth is None:
        raise RuntimeError(f'No notarization credentials: add ASC_KEY_ID, ASC_ISSUER_ID and the matching '
                           f'AuthKey_<id>.p8 under {directory}, or pass --notary-profile')
    return auth


def notarize(path, auth, output, prefix=''):
    """Submit, wait (ten-minute limit), and require Accepted. Returns (submission id, result)."""
    submitted = run(['xcrun', 'notarytool', 'submit', str(path), *auth,
                     '--output-format', 'json'], timeout=300)
    (output / f'{prefix}notarization-submit-output.json').write_text(submitted)
    submission = json.loads(submitted)
    (output / f'{prefix}notarization-submission.json').write_text(json.dumps(submission, indent=2) + '\n')
    submission_id = submission['id']
    print(f'Apple submission {submission_id}; waiting up to ten minutes', flush=True)
    try:
        status = json.loads(run(['xcrun', 'notarytool', 'wait', submission_id, *auth,
                                 '--output-format', 'json', '--timeout', '10m'], timeout=630))
    except Exception:
        run(['xcrun', 'notarytool', 'info', submission_id, *auth,
             '--output-format', 'json'], log=output / f'{prefix}notarization-last-status.json')
        raise
    (output / f'{prefix}notarization-result.json').write_text(json.dumps(status, indent=2) + '\n')
    if status.get('status') != 'Accepted':
        run(['xcrun', 'notarytool', 'log', submission_id, *auth],
            log=output / f'{prefix}notarization-rejection.json')
        raise RuntimeError(f'Apple did not accept this file: {status.get("status")}')
    return submission_id, status


def verify_disk_image(image, output, label):
    """Signature, ticket and Gatekeeper checks on the DMG, then on the app inside it."""
    run(['codesign', '--verify', '--strict', str(image)])
    run(['xcrun', 'stapler', 'validate', str(image)], log=output / f'{label}-staple.log')
    run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
         '--verbose=2', str(image)], log=output / f'{label}-gatekeeper.log')
    with tempfile.TemporaryDirectory(prefix='dilated-dmg-mount-') as mount:
        run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, str(image)],
            timeout=180)
        try:
            volume = Path(mount)
            if not (volume / 'Applications').is_symlink() or os.readlink(volume / 'Applications') != '/Applications':
                raise RuntimeError('The DMG must carry an Applications alias')
            verify_app(volume / 'Dilated.app', output, f'{label}-app')
        finally:
            run(['hdiutil', 'detach', mount], timeout=120)


def create_disk_image(app, image, identity):
    root = Path(__file__).resolve().parent.parent
    run([sys.executable, str(root / 'scripts/build-dmg.py'), '--app', str(app), '--output', str(image),
         '--identity', identity], cwd=root, timeout=900)
    return image


def build_app(root, output, identity, enable_updates=False):
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment['DILATED_BUILD_DIR'] = str(output)
    environment['DILATED_SIGN_IDENTITY'] = identity
    environment['DILATED_ENABLE_UPDATES'] = '1' if enable_updates else '0'
    with (output / 'build.log').open('w') as log:
        subprocess.run(['bash', 'scripts/build-app.sh', 'release'], cwd=root, env=environment,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notary-profile', help='Keychain profile; overrides the default App Store Connect API key')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--check-automation', type=Path, help='Validate local app automation payload only')
    parser.add_argument('--identity', default='Developer ID Application: Scott Benson (3524374A2S)')
    parser.add_argument('--candidate', action='store_true', help='Build a clean local test candidate without a release tag; it cannot be published')
    args = parser.parse_args()
    if args.check_automation:
        validate_automation_bundle(args.check_automation)
        return
    if args.output_dir is None:
        parser.error('--output-dir is required when building a release')
    auth = notary_auth(args.notary_profile)
    root = Path(__file__).resolve().parent.parent
    metadata = release_metadata(root)
    version = metadata['DilatedDisplayVersion']
    source = verify_source(root, version, candidate=args.candidate)
    if run(['uname', '-m']).strip() != 'arm64':
        raise RuntimeError('Build this release on an Apple Silicon Mac')
    output = create_output(args.output_dir.resolve(), f'{version}-{source[:12]}' if args.candidate else version)
    app = output / 'Dilated.app'
    print(f'Building {version} from {source}', flush=True)
    build_app(root, output, args.identity, enable_updates=not args.candidate)
    validate_helper_bundle(app)
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    for key in ('DilatedDisplayVersion', 'CFBundleShortVersionString', 'CFBundleVersion'):
        if info.get(key) != metadata[key]:
            raise RuntimeError(f'Built app has the wrong {key}')
    if info.get('DilatedSourceRevision') != source:
        raise RuntimeError('Built app does not identify the release source')
    identity = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Developer ID Application:' not in identity or 'TeamIdentifier=3524374A2S' not in identity:
        raise RuntimeError('A CodesWhat Developer ID signature is required')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    upload = output / 'notarization-upload.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(upload)], timeout=180)
    print('Submitting the signed app to Apple', flush=True)
    submission_id, status = notarize(upload, auth, output)
    run(['xcrun', 'stapler', 'staple', str(app)], log=output / 'stapling.log')
    verify_app(app, output, 'original')
    print('Apple accepted the app; building and checking the final ZIP', flush=True)
    filename = f'Dilated-{version}-macos-arm64.zip'
    archive = output / filename
    create_update_archive(app, archive)
    with tempfile.TemporaryDirectory(prefix='dilated-package-') as temporary:
        extracted = Path(temporary) / 'extracted'
        run(['ditto', '-x', '-k', str(archive), str(extracted)], timeout=180)
        verify_app(extracted / 'Dilated.app', output, 'extracted')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print('Building the DMG installer from the stapled app', flush=True)
    image_name = f'Dilated-{version}-macos-arm64.dmg'
    image = create_disk_image(app, output / image_name, dmg_identity(identity))
    print('Submitting the signed DMG to Apple', flush=True)
    image_submission_id, image_status = notarize(image, auth, output, 'dmg-')
    run(['xcrun', 'stapler', 'staple', str(image)], log=output / 'dmg-stapling.log')
    verify_disk_image(image, output, 'dmg')
    image_digest = hashlib.sha256(image.read_bytes()).hexdigest()
    (output / f'{image_name}.sha256').write_text(f'{image_digest}  {image_name}\n')
    (output / f'{filename}.sha256').write_text(f'{digest}  {filename}\n')
    manifest = {'version': version, 'build': metadata['CFBundleVersion'],
                'candidate': args.candidate, 'tag': None if args.candidate else f'v{version}',
                'updatesEnabled': info.get('DilatedUpdatesEnabled') is True,
                'sourceRevision': source, 'architecture': 'arm64', 'minimumMacOS': '26.0',
                'archive': filename, 'archiveSHA256': digest, 'archiveBytes': archive.stat().st_size,
                'notarizationID': submission_id, 'notarizationStatus': status['status'],
                'signatureVerified': True, 'stapleVerified': True, 'extractedGatekeeperAccepted': True,
                'dmg': image_name, 'dmgSHA256': image_digest, 'dmgBytes': image.stat().st_size,
                'dmgNotarizationID': image_submission_id, 'dmgNotarizationStatus': image_status['status'],
                'dmgSignatureVerified': True, 'dmgStapleVerified': True, 'dmgGatekeeperAccepted': True,
                'freshInstallVerified': False}
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    upload.unlink()
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == '__main__':
    main()
