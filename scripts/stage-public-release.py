#!/usr/bin/env python3
"""Stage a checked release, source archive and signed Sparkle feed for the website."""
# Adapted from Mouthtype, Scott Benson, under the Dilated MIT author grant.
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('package_release', ROOT / 'scripts/package-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

DISTRIBUTION_CHECKS = (
    'signatureVerified', 'stapleVerified', 'extractedGatekeeperAccepted',
    'dmgSignatureVerified', 'dmgStapleVerified', 'dmgGatekeeperAccepted', 'updatesEnabled',
)
PRERELEASE_VERSION = re.compile(r'-(?:alpha|beta|rc)\.[1-9]\d*$')
PRERELEASE_REQUIRED_CHECKS = ('macOS26ClosedLid', 'heartbeatExpiry', 'stopResume')
ACCEPTANCE_STATUSES = ('passed', 'failed', 'notRun')
ACCEPTANCE_CHECKS = (
    'macOS26ClosedLid', 'macOS27ClosedLid', 'helperCrashRecovery', 'appCrashRecovery',
    'heartbeatExpiry', 'stopResume', 'guardTransitions', 'rebootRecovery', 'approvalDenied',
    'helperUpgrade', 'sparkleUpgrade', 'cleanInstallSecondMac', 'uninstallNormalSleep', 'nativeUI',
)


def validate_archive(directory):
    manifest = json.loads((directory / 'release-manifest.json').read_text())
    version = manifest.get('version', '')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.[1-9]\d*)?', version):
        raise RuntimeError('Invalid release version')
    if manifest.get('candidate') is not False or manifest.get('tag') != f'v{version}':
        raise RuntimeError('Local candidates cannot be published; an exact release tag is required')
    if manifest.get('architecture') != 'arm64' or manifest.get('minimumMacOS') != '26.0':
        raise RuntimeError('Release platform requirements must match Dilated')
    if manifest['notarizationStatus'] != 'Accepted':
        raise RuntimeError('Accepted notarization is required')
    if not all(manifest.get(key) is True for key in DISTRIBUTION_CHECKS):
        raise RuntimeError('All distribution checks must pass')
    if manifest['archive'] != f"Dilated-{manifest['version']}-macos-arm64.zip":
        raise RuntimeError('Release version and archive filename must agree')
    archive = directory / manifest['archive']
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['archiveSHA256']:
        raise RuntimeError('Archive checksum does not match the checked release')
    if archive.stat().st_size != manifest['archiveBytes']:
        raise RuntimeError('Archive length does not match the checked release')
    validate_disk_image(directory, manifest)
    return manifest


def validate_acceptance(record, manifest):
    for key in ('version', 'build', 'sourceRevision', 'archiveSHA256', 'dmgSHA256'):
        if record.get(key) != manifest.get(key):
            raise RuntimeError(f'Hardware acceptance must match this release: {key}')
    checks = record.get('checks', {})
    prerelease = bool(PRERELEASE_VERSION.search(manifest['version']))
    if not prerelease:
        for key in ACCEPTANCE_CHECKS:
            check = checks.get(key, {})
            if check.get('status') != 'passed' or not all(
                isinstance(check.get(field), str) and check[field].strip()
                for field in ('machine', 'macOS', 'evidence')
            ):
                raise RuntimeError(f'Required acceptance check has not passed: {key}')
        for major in ('26', '27'):
            if not checks[f'macOS{major}ClosedLid']['macOS'].startswith(major + '.'):
                raise RuntimeError(f'The lid check must run on macOS {major}')
        if checks['cleanInstallSecondMac']['machine'] == checks['macOS26ClosedLid']['machine']:
            raise RuntimeError('A clean install on a second Mac is required')
        return {'prerelease': False, 'passed': list(ACCEPTANCE_CHECKS), 'failed': [], 'notRun': []}

    def text(check, field):
        return isinstance(check.get(field), str) and bool(check[field].strip())

    for key in ACCEPTANCE_CHECKS:
        check = checks.get(key)
        if not isinstance(check, dict) or check.get('status') not in ACCEPTANCE_STATUSES:
            raise RuntimeError(f'Prerelease acceptance must record a passed, failed or notRun status: {key}')
        if not text(check, 'evidence'):
            raise RuntimeError(f'Prerelease acceptance must record evidence for every check: {key}')
        if check['status'] == 'passed' and not (text(check, 'machine') and text(check, 'macOS')):
            raise RuntimeError(f'A passed acceptance check needs a machine and macOS: {key}')
    for key in PRERELEASE_REQUIRED_CHECKS:
        if checks[key]['status'] != 'passed':
            raise RuntimeError(f'Required acceptance check has not passed: {key}')
    lid26 = checks['macOS26ClosedLid']
    if lid26['status'] == 'passed' and not lid26['macOS'].startswith('26.'):
        raise RuntimeError('The lid check must run on macOS 26')
    lid27 = checks['macOS27ClosedLid']
    if lid27['status'] == 'passed' and not lid27['macOS'].startswith('27.'):
        raise RuntimeError('The lid check must run on macOS 27')
    second = checks['cleanInstallSecondMac']
    if second['status'] == 'passed' and second['machine'] == checks['macOS26ClosedLid']['machine']:
        raise RuntimeError('A clean install on a second Mac is required')
    return {'prerelease': True, **{
        status: [key for key in ACCEPTANCE_CHECKS if checks[key]['status'] == status]
        for status in ACCEPTANCE_STATUSES
    }}


def acceptance_verified(summary):
    return not summary['prerelease'] or not (summary['failed'] or summary['notRun'])


def latest_metadata(manifest, acceptance):
    return {
        'released': True, 'version': manifest['version'], 'build': manifest['build'],
        'downloadURL': f"./releases/{manifest['version']}/{manifest['dmg']}",
        'sha256': manifest['dmgSHA256'], 'minimumMacOS': manifest['minimumMacOS'],
        'architecture': manifest['architecture'],
        'prerelease': acceptance['prerelease'],
        'unverified': acceptance['failed'] + acceptance['notRun'],
    }


def validate_disk_image(directory, manifest):
    """The DMG is the public download, so it needs its own notarization and checksum evidence."""
    if manifest.get('dmg') != f"Dilated-{manifest['version']}-macos-arm64.dmg":
        raise RuntimeError('Release version and DMG filename must agree')
    if manifest.get('dmgNotarizationStatus') != 'Accepted':
        raise RuntimeError('Accepted DMG notarization is required')
    if not all(manifest.get(key) is True for key in (
        'dmgSignatureVerified', 'dmgStapleVerified', 'dmgGatekeeperAccepted'
    )):
        raise RuntimeError('All DMG distribution checks must pass')
    image = directory / manifest['dmg']
    if hashlib.sha256(image.read_bytes()).hexdigest() != manifest['dmgSHA256']:
        raise RuntimeError('DMG checksum does not match the checked release')
    if image.stat().st_size != manifest['dmgBytes']:
        raise RuntimeError('DMG length does not match the checked release')


def retain_public_assets(staged, retained):
    feed = (staged / 'updates/appcast.xml').read_bytes()
    latest = (staged / 'releases/latest.json').read_bytes()
    files = [path for path in (staged / 'releases').rglob('*') if path.is_file() and path != staged / 'releases/latest.json']
    for path in files:
        destination = retained / path.relative_to(staged)
        if destination.exists() and destination.read_bytes() != path.read_bytes():
            raise RuntimeError(f'Published release files are immutable: {destination.name}')
    for path in files:
        destination = retained / path.relative_to(staged)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    (retained / 'updates').mkdir(parents=True, exist_ok=True)
    temporary = retained / 'updates/appcast.xml.new'
    temporary.write_bytes(feed)
    os.replace(temporary, retained / 'updates/appcast.xml')
    temporary = retained / 'releases/latest.json.new'
    temporary.write_bytes(latest)
    os.replace(temporary, retained / 'releases/latest.json')


def validate_feed_build(feed, build):
    namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    versions = [int(item.text) for item in ET.parse(feed).iter(namespace + 'version')]
    if not versions or int(build) != max(versions):
        raise RuntimeError('The advertised download must be the newest build in the signed feed')


def cask_text(manifest, acceptance=None):
    version = manifest.get('version')
    digest = manifest.get('dmgSHA256')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.[1-9]\d*)?', version):
        raise ValueError('Invalid cask version')
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('Invalid cask DMG checksum')
    caveats = ''
    unverified = acceptance['failed'] + acceptance['notRun'] if acceptance and acceptance['prerelease'] else []
    if unverified:
        caveats = (f'    Beta release. Closed-lid mode is experimental.\n'
                   f'    Not yet verified on hardware: {", ".join(unverified)}.\n\n')
    livecheck = ''
    if PRERELEASE_VERSION.search(version):
        # The tap lists dilated in audit_exceptions/github_prerelease_allowlist.json.
        # At the first stable release, drop this skip (or replace it with a
        # github_releases livecheck) and tell the tap to remove the allowlist entry.
        livecheck = (f'\n  livecheck do\n'
                     f'    skip "Public beta; versions are tracked by scripts/check-cask-drift.sh."\n'
                     f'  end\n\n')
    return f'''cask "dilated" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/CodesWhat/dilated/releases/download/v#{{version}}/Dilated-#{{version}}-macos-arm64.dmg"
  name "Dilated"
  desc "Keep your Mac awake, with reasons"
  homepage "https://dilated.codeswhat.com/"
{livecheck}  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Dilated.app"
  binary "#{{appdir}}/Dilated.app/Contents/MacOS/dilated"

  uninstall_preflight_steps do
    run "Dilated.app/Contents/MacOS/dilated", base: :appdir, args: ["package-check"]
  end

  caveats <<~EOS
{caveats}    Before upgrading, run dilated prepare-update, then brew upgrade --cask dilated.
    Reopen Dilated after the upgrade. Timers keep their original deadlines.
    Before removing, run dilated prepare-uninstall, then brew uninstall --cask dilated.
    Preparation expires after ten minutes. Normal uninstall preserves preferences.
  EOS
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release_directory', type=Path)
    parser.add_argument('--sparkle-account', default='com.codeswhat.dilated')
    parser.add_argument('--public-dir', required=True, type=Path,
                        help='Retained public artifact directory; keep it across releases')
    parser.add_argument('--acceptance', required=True, type=Path,
                        help='Hardware/install evidence tied to these exact release artifacts')
    args = parser.parse_args()
    directory = args.release_directory.resolve()
    manifest = validate_archive(directory)
    summary = validate_acceptance(json.loads(args.acceptance.read_text()), manifest)
    version = manifest['version']
    metadata = release.release_metadata(ROOT)
    source = release.verify_source(ROOT, version)
    if metadata['DilatedDisplayVersion'] != version or source != manifest['sourceRevision']:
        raise RuntimeError('Release archive and checked source must agree')
    if metadata['CFBundleVersion'] != manifest['build']:
        raise RuntimeError('Release build numbers must agree')
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    if not (tools / 'generate_appcast').is_file():
        raise RuntimeError('Resolve the pinned Sparkle package before staging')
    public_key = release.run([str(tools / 'generate_keys'), '--account', args.sparkle_account, '-p']).strip()
    with (directory / 'Dilated.app/Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if (info.get('SUPublicEDKey') != public_key or info.get('SURequireSignedFeed') is not True
            or info.get('SUVerifyUpdateBeforeExtraction') is not True
            or info.get('DilatedUpdatesEnabled') is not True
            or info.get('SUFeedURL') != 'https://dilated.codeswhat.com/updates/appcast.xml'):
        raise RuntimeError('The app must require the feed signing key used for publication')
    release.verify_disk_image(directory / manifest['dmg'], directory, 'public-dmg')
    with tempfile.TemporaryDirectory(prefix='dilated-public-check-') as temporary:
        extracted = Path(temporary)
        release.run(['ditto', '-x', '-k', str(directory / manifest['archive']), str(extracted)], timeout=180)
        release.verify_app(extracted / 'Dilated.app', directory, 'public-extracted')
        with (extracted / 'Dilated.app/Contents/Info.plist').open('rb') as file:
            extracted_info = plistlib.load(file)
        if extracted_info != info or info.get('DilatedSourceRevision') != source:
            raise RuntimeError('Extracted app metadata must match the checked source')
    output = directory / 'public'
    output.mkdir(exist_ok=False)
    releases = output / 'releases' / version
    updates = output / 'updates'
    releases.mkdir(parents=True)
    updates.mkdir()
    archive = directory / manifest['archive']
    shutil.copy2(archive, releases / archive.name)
    shutil.copy2(directory / f'{archive.name}.sha256', releases / f'{archive.name}.sha256')
    for name in (manifest['dmg'], f"{manifest['dmg']}.sha256"):
        shutil.copy2(directory / name, releases / name)
    source_archive = releases / f'Dilated-{version}-source.tar.gz'
    release.run(['git', 'archive', '--format=tar.gz', f'--prefix=Dilated-{version}-source/',
                 f'--output={source_archive}', source], cwd=ROOT, timeout=180)
    source_digest = hashlib.sha256(source_archive.read_bytes()).hexdigest()
    (releases / f'{source_archive.name}.sha256').write_text(f'{source_digest}  {source_archive.name}\n')
    public_manifest = {**manifest, 'sourceArchive': source_archive.name, 'sourceSHA256': source_digest,
                       'freshInstallVerified': True, 'prerelease': summary['prerelease'],
                       'acceptance': summary,
                       'acceptanceVerified': acceptance_verified(summary)}
    cask = cask_text(manifest, summary).encode()
    (releases / 'dilated.rb').write_bytes(cask)
    public_manifest.update(cask='dilated.rb', caskSHA256=hashlib.sha256(cask).hexdigest())
    (releases / 'release-manifest.json').write_text(json.dumps(public_manifest, indent=2) + '\n')
    (output / 'releases/latest.json').write_text(json.dumps(latest_metadata(manifest, summary), indent=2) + '\n')
    with tempfile.TemporaryDirectory(prefix='dilated-appcast-') as temporary:
        feed_directory = Path(temporary)
        shutil.copy2(archive, feed_directory / archive.name)
        shutil.copy2(ROOT / 'packaging/ReleaseNotes.txt', feed_directory / f'{archive.stem}.txt')
        release.run([str(tools / 'generate_appcast'), '--account', args.sparkle_account,
                     '--download-url-prefix', f'https://dilated.codeswhat.com/releases/{version}/',
                     '--link', 'https://dilated.codeswhat.com/', '--embed-release-notes',
                     '--maximum-deltas', '0', str(feed_directory)], timeout=180,
                    log=directory / 'appcast-generation.log')
        feed = feed_directory / 'appcast.xml'
        release.run([str(tools / 'sign_update'), '--account', args.sparkle_account, '--verify', str(feed)])
        validate_feed_build(feed, manifest['build'])
        shutil.copy2(feed, updates / 'appcast.xml')
    retain_public_assets(output, args.public_dir.resolve())
    print(json.dumps({'publicDirectory': str(args.public_dir.resolve()), 'version': version,
                      'archiveSHA256': manifest['archiveSHA256'], 'dmgSHA256': manifest['dmgSHA256'],
                      'signedFeedVerified': True,
                      'sourceSHA256': source_digest}, indent=2))


if __name__ == '__main__':
    main()
