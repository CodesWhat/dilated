#!/usr/bin/env python3
"""Publish only committed website files plus retained, checked public releases."""
# Adapted from Mouthtype, Scott Benson, under the Dilated MIT author grant.
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('public_release', ROOT / 'scripts/stage-public-release.py')
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
run = public.release.run

SPARKLE_ACCOUNT = 'com.codeswhat.dilated'
VERCEL_PROJECT = {'orgId': 'team_A8tovHIXay3cbUMOtLBijJSk', 'projectId': 'prj_OjusnY04zZgqMWxvu1bumDlrVkTA'}


def redirect_targets(root):
    routes = json.loads((root / 'website/vercel.json').read_text()).get('routes', [])
    return {item['src']: item['headers']['Location'] for item in routes if item.get('status') == 302}


def select_release(assets, redirects):
    """Check every retained release and return the one the website advertises."""
    manifests = sorted((assets / 'releases').glob('*/release-manifest.json'))
    if not manifests:
        raise RuntimeError('Retained public release artifacts are required')
    selected = None
    for path in manifests:
        manifest = public.validate_archive(path.parent)
        if path.parent.name != manifest['version']:
            raise RuntimeError('Release directory name must match its manifest version')
        source_file = path.parent / f"Dilated-{manifest['version']}-source.tar.gz"
        if (source_file.name != manifest.get('sourceArchive') or not source_file.is_file()
                or hashlib.sha256(source_file.read_bytes()).hexdigest() != manifest.get('sourceSHA256')):
            raise RuntimeError('Corresponding source archive checksum must match')
        prefix = f"/releases/{manifest['version']}/"
        if redirects.get('/download/file') == prefix + manifest['dmg']:
            if redirects.get('/source') != prefix + source_file.name:
                raise RuntimeError('Download and source routes must describe the same release')
            selected = manifest
    if selected is None:
        raise RuntimeError('The advertised download is not among the checked artifacts (it must be the DMG)')
    return selected


def validate_latest(assets, manifest):
    try:
        latest = json.loads((assets / 'releases/latest.json').read_text())
    except (OSError, ValueError):
        latest = None
    acceptance = manifest.get('acceptance') or {}
    expected = {
        'version': manifest['version'], 'build': str(manifest['build']),
        'sha256': manifest['dmgSHA256'],
        'downloadURL': f"./releases/{manifest['version']}/{manifest['dmg']}",
        'released': True, 'prerelease': bool(manifest.get('prerelease', False)),
        'unverified': list(acceptance.get('failed', [])) + list(acceptance.get('notRun', [])),
    }
    if not isinstance(latest, dict):
        raise RuntimeError('latest.json must describe the advertised release')
    actual = {**latest, 'build': str(latest.get('build'))}
    if any(actual.get(key) != value for key, value in expected.items()) or any(
            latest.get(key) is not expected[key] for key in ('released', 'prerelease')):
        raise RuntimeError('latest.json must describe the advertised release')


def validate(root, assets):
    if run(['git', 'status', '--porcelain'], cwd=root).strip():
        raise RuntimeError('Publish from a clean reviewed checkout')
    source = run(['git', 'rev-parse', 'HEAD'], cwd=root).strip()
    selected = select_release(assets, redirect_targets(root))
    validate_latest(assets, selected)
    feed = assets / 'updates/appcast.xml'
    if not feed.is_file():
        raise RuntimeError('The retained signed feed is required')
    public.validate_feed_build(feed, selected['build'])
    tools = root / '.build/artifacts/sparkle/Sparkle/bin'
    run([str(tools / 'sign_update'), '--account', SPARKLE_ACCOUNT, '--verify', str(feed)])
    return source, selected


def build_staging(root, source, assets, staging):
    """Deploy root: committed website/dist, the committed vercel.json and the retained public files."""
    export = staging / 'export'
    export.mkdir()
    archive = staging / 'website.tar'
    run(['git', 'archive', f'--output={archive}', source, 'website/dist', 'website/vercel.json'], cwd=root)
    run(['tar', '-xf', str(archive), '-C', str(export)])
    archive.unlink()
    deploy = staging / 'deploy'
    shutil.copytree(export / 'website/dist', deploy)
    for name in ('releases', 'updates'):
        if (deploy / name).exists():
            raise RuntimeError(f'website/dist must not contain {name}; release files come from the retained directory')
        shutil.copytree(assets / name, deploy / name)
    shutil.copy2(export / 'website/vercel.json', deploy / 'vercel.json')
    (deploy / '.vercel').mkdir()
    (deploy / '.vercel/project.json').write_text(json.dumps(VERCEL_PROJECT))
    return deploy


def check_live_coverage(assets, live):
    """Refuse a deploy that would drop a release the live site still references."""
    latest, versions = live
    have = public.release_directories(assets)
    if len(have) == 1 and latest and latest not in have:
        raise RuntimeError(
            f'Single-release public dir: {assets} holds only {sorted(have)[0]} but the live site is at {latest}. '
            'Deploying it would replace the whole site and drop every earlier release. '
            'Use the retained build/public-release-assets from the main checkout.')
    missing = sorted(versions - have)
    if missing:
        raise RuntimeError(f"Public dir is missing releases the live site references: {', '.join(missing)}")
    if len(have) < len(versions):
        raise RuntimeError(f'Public dir holds {len(have)} releases but the live site lists {len(versions)}')


def main(argv=None, fetch=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-dir', type=Path,
                        help='Default: build/public-release-assets in the main checkout')
    parser.add_argument('--production', action='store_true', help='Publish after validation; otherwise check only')
    parser.add_argument('--allow-offline', action='store_true',
                        help='Publish even if the live site cannot be fetched to compare releases')
    args = parser.parse_args(argv)
    public_dir = (args.public_dir or public.default_public_dir()).resolve()
    source, selected = validate(ROOT, public_dir)
    if not args.production:
        print(f"Checked website {source} and release {selected['version']}; nothing published")
        return
    try:
        live = public.live_releases(fetch or public.fetch_live)
    except Exception as error:
        if not args.allow_offline:
            raise RuntimeError(f'Cannot fetch the live site to compare releases ({error}); '
                               'pass --allow-offline to publish anyway') from error
        print(f'WARNING: live site unreachable ({error}); publishing without the release comparison')
    else:
        check_live_coverage(public_dir, live)
    with tempfile.TemporaryDirectory(prefix='dilated-website-publish-') as temporary:
        deploy = build_staging(ROOT, source, public_dir, Path(temporary))
        result = run(['vercel', 'deploy', str(deploy), '--prod', '--yes', '--scope', 'codeswhat',
                      '--meta', f'sourceCommit={source}', '--meta', 'sourceRepository=CodesWhat/dilated'], timeout=600)
        print(result)
    print(f"Published release {selected['version']}; verify the public download and feed before announcing it")


if __name__ == '__main__':
    main()
