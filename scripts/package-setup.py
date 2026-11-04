#!/usr/bin/env python3
"""Build, sign and notarize Dilated Closed-Lid Setup.app as its own Developer ID artifact."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location('package_release', ROOT / 'scripts/package-release.py')
release = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release)

APP_NAME = 'Dilated Closed-Lid Setup'
BUNDLE_ID = 'com.codeswhat.dilated.closed-lid-setup'
EXECUTABLE = 'DilatedSetup'
RESOURCE_BUNDLE = 'Dilated_DilatedSetupCore.bundle'
RESOURCE_BUNDLE_ID = f'{BUNDLE_ID}.resources'
TEAM_ID = '3524374A2S'


def minimum_system_version(root):
    with (root / 'packaging/Info.plist').open('rb') as file:
        return plistlib.load(file)['LSMinimumSystemVersion']


def setup_info(metadata, source, minimum):
    return {
        'CFBundleName': APP_NAME,
        'CFBundleDisplayName': APP_NAME,
        'CFBundleExecutable': EXECUTABLE,
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': metadata['CFBundleShortVersionString'],
        'CFBundleVersion': metadata['CFBundleVersion'],
        'DilatedDisplayVersion': metadata['DilatedDisplayVersion'],
        'DilatedSourceRevision': source,
        'LSMinimumSystemVersion': minimum,
        'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'Copyright © CodesWhat. Licensed under MIT.',
    }


def build_executable(root, scratch, log):
    """Release build for arm64. Returns (executable, resource bundle). The scratch directory is kept
    out of the source tree so SwiftPM's absolute-path fallback can be removed before the runtime check."""
    base = ['swift', 'build', '-c', 'release', '--arch', 'arm64', '--scratch-path', str(scratch)]
    try:
        release.run([*base, '--product', EXECUTABLE], cwd=root, timeout=1200, log=log)
    except subprocess.CalledProcessError as error:
        tail = '\n'.join(Path(log).read_text(errors='replace').splitlines()[-60:])
        raise RuntimeError(f'swift build failed (exit {error.returncode}); last lines:\n{tail}') from error
    bin_path = Path(release.run([*base, '--show-bin-path'], cwd=root).strip())
    executable, bundle = bin_path / EXECUTABLE, bin_path / RESOURCE_BUNDLE
    if not executable.is_file() or not bundle.is_dir():
        raise RuntimeError(f'Build did not produce {EXECUTABLE} and {RESOURCE_BUNDLE} in {bin_path}')
    return executable, bundle


def assemble_app(app, executable, resource_bundle, info, root=ROOT):
    """Lay out the .app. `Bundle.module` for an executable looks in Bundle.main.resourceURL, which is
    Contents/Resources, so the SwiftPM resource bundle goes there."""
    macos, resources = app / 'Contents/MacOS', app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(executable, macos / EXECUTABLE)
    bundle = resources / RESOURCE_BUNDLE
    shutil.copytree(resource_bundle, bundle, symlinks=True)
    subprocess.run([sys.executable, str(root / 'scripts/normalize-resource-bundle.py'), str(bundle)], check=True)
    # SwiftPM derives this identifier from the checkout path; pin it so it doesn't depend on where we built.
    plist_path = bundle / 'Contents/Info.plist'
    with plist_path.open('rb') as file:
        bundle_info = plistlib.load(file)
    bundle_info['CFBundleIdentifier'] = RESOURCE_BUNDLE_ID
    plist_path.write_bytes(plistlib.dumps(bundle_info))
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    return app


def sign_commands(app, identity):
    """Inside-out: resource bundle, main executable, then the app. Hardened runtime and a secure
    timestamp, no entitlements."""
    common = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity]
    return [
        [*common, str(app / 'Contents/Resources' / RESOURCE_BUNDLE)],
        [*common, str(app / 'Contents/MacOS' / EXECUTABLE)],
        [*common, str(app)],
    ]


def sign_app(app, identity):
    for command in sign_commands(app, identity):
        release.run(command, timeout=180)
    release.run(['codesign', '--verify', '--deep', '--strict', str(app)])
    identity_output = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True,
                                     check=True).stderr
    if 'Authority=Developer ID Application:' not in identity_output or f'TeamIdentifier={TEAM_ID}' not in identity_output:
        raise RuntimeError('A CodesWhat Developer ID signature is required')
    if 'flags=0x10000(runtime)' not in identity_output:
        raise RuntimeError('The app must be signed with the hardened runtime')


def expected_script_sha256(root):
    source = (root / 'Sources/DilatedSetupCore/ClosedLidSetupModels.swift').read_text()
    match = re.search(r'expectedScriptSHA256 =\s*"([0-9a-f]{64})"', source)
    if not match:
        raise RuntimeError('Could not read expectedScriptSHA256 from the setup sources')
    return match.group(1)


def check_packaged_app(app, root=ROOT):
    """Run the packaged executable: its bundled script and LaunchAgent template must resolve through
    Bundle.module and match the pinned hash, and the status readout must work."""
    executable = str(app / 'Contents/MacOS' / EXECUTABLE)
    assets = json.loads(release.run([executable, '--assets', '--json'], timeout=30))
    expected = expected_script_sha256(root)
    on_disk = hashlib.sha256((app / 'Contents/Resources' / RESOURCE_BUNDLE
                              / 'Contents/Resources/dilated-power').read_bytes()).hexdigest()
    if not (assets.get('scriptMatches') is True and assets.get('plistValid') is True
            and assets.get('scriptSHA256') == expected == on_disk):
        raise RuntimeError(f'Bundled assets do not resolve or match at runtime: {assets}')
    status = json.loads(release.run([executable, '--status', '--json'], timeout=30))
    for key in ('rule', 'script', 'agent', 'ruleInstalledByCompanion'):
        if key not in status:
            raise RuntimeError(f'Status output is missing {key}: {status}')
    return assets, status


def verify_app(app, output, label):
    release.run(['codesign', '--verify', '--deep', '--strict', '-vv', str(app)])
    release.run(['xcrun', 'stapler', 'validate', str(app)], log=output / f'{label}-staple.log')
    release.run(['spctl', '--assess', '--type', 'execute', '-vv', str(app)], log=output / f'{label}-gatekeeper.log')
    if 'Notarized Developer ID' not in (output / f'{label}-gatekeeper.log').read_text():
        raise RuntimeError('Gatekeeper did not report Notarized Developer ID')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notary-profile', help='Keychain profile; overrides the default App Store Connect API key')
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--identity', default='Developer ID Application: Scott Benson (3524374A2S)')
    parser.add_argument('--candidate', action='store_true',
                        help='Build from a clean tree without a release tag; it cannot be published')
    args = parser.parse_args()
    auth = release.notary_auth(args.notary_profile)
    metadata = release.release_metadata(ROOT)
    version = metadata['DilatedDisplayVersion']
    source = release.verify_source(ROOT, version, candidate=args.candidate)
    if release.run(['uname', '-m']).strip() != 'arm64':
        raise RuntimeError('Build this artifact on an Apple Silicon Mac')
    output = release.create_output(args.output_dir.resolve(), f'{version}-{source[:12]}' if args.candidate else version)
    app = output / f'{APP_NAME}.app'
    print(f'Building {APP_NAME} {version} from {source}', flush=True)
    with tempfile.TemporaryDirectory(prefix='dilated-setup-build-') as scratch:
        executable, resource_bundle = build_executable(ROOT, Path(scratch) / 'build', output / 'build.log')
        assemble_app(app, executable, resource_bundle,
                     setup_info(metadata, source, minimum_system_version(ROOT)))
    # The scratch build is gone now, so SwiftPM's absolute-path lookup can't hide a bad bundle layout.
    sign_app(app, args.identity)
    upload = output / 'notarization-upload.zip'
    release.run(['ditto', '-c', '-k', '--keepParent', str(app), str(upload)], timeout=180)
    print('Submitting the signed app to Apple', flush=True)
    submission_id, status = release.notarize(upload, auth, output)
    release.run(['xcrun', 'stapler', 'staple', str(app)], log=output / 'stapling.log')
    verify_app(app, output, 'original')
    check_packaged_app(app)
    filename = f'Dilated-Closed-Lid-Setup-{version}-macos-arm64.zip'
    archive = output / filename
    release.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], timeout=180)
    with tempfile.TemporaryDirectory(prefix='dilated-setup-extract-') as temporary:
        extracted = Path(temporary) / 'extracted'
        release.run(['ditto', '-x', '-k', str(archive), str(extracted)], timeout=180)
        verify_app(extracted / f'{APP_NAME}.app', output, 'extracted')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / f'{filename}.sha256').write_text(f'{digest}  {filename}\n')
    manifest = {'name': APP_NAME, 'bundleID': BUNDLE_ID, 'version': version, 'build': metadata['CFBundleVersion'],
                'candidate': args.candidate, 'sourceRevision': source, 'architecture': 'arm64',
                'minimumMacOS': minimum_system_version(ROOT), 'archive': filename, 'archiveSHA256': digest,
                'archiveBytes': archive.stat().st_size, 'notarizationID': submission_id,
                'notarizationStatus': status['status']}
    (output / 'setup-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    upload.unlink()
    print(json.dumps(manifest, indent=2), flush=True)


if __name__ == '__main__':
    main()
