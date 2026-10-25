import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publish_website', ROOT / 'scripts/publish-website.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)
real_run = publish.run

VERSION = '1.0.0-beta.1'
FEED = '''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><sparkle:version>{build}</sparkle:version></item>
</channel></rss>
'''


class PublishWebsiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dilated-website-test-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.repo = base / 'repo'
        self.assets = base / 'assets'
        self.calls = []
        (self.repo / 'website/dist').mkdir(parents=True)
        (self.repo / 'website/dist/index.html').write_text('<h1>Dilated</h1>')
        self.write_routes(VERSION)
        self.git('init', '-q')
        self.commit()
        self.make_release(VERSION, '2')
        self.write_feed('2')

        def fake_run(args, **kwargs):
            if args[0] in ('git', 'tar'):
                return real_run(args, **kwargs)
            self.calls.append(args)
            return 'deployed\n'

        original = publish.run
        publish.run = fake_run
        self.addCleanup(setattr, publish, 'run', original)

    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args],
                              cwd=self.repo, check=True, capture_output=True, text=True).stdout

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'fixture')

    def write_routes(self, version, dmg=None, source=None):
        prefix = f'/releases/{version}/'
        routes = [
            {'src': '/download/file', 'status': 302, 'headers': {
                'Location': prefix + (dmg or f'Dilated-{version}-macos-arm64.dmg')}},
            {'src': '/source', 'status': 302, 'headers': {
                'Location': prefix + (source or f'Dilated-{version}-source.tar.gz')}},
        ]
        (self.repo / 'website/vercel.json').write_text(json.dumps({'routes': routes}))

    def make_release(self, version, build):
        directory = self.assets / 'releases' / version
        directory.mkdir(parents=True)
        manifest = {
            'version': version, 'build': build, 'candidate': False, 'tag': f'v{version}',
            'architecture': 'arm64', 'minimumMacOS': '26.0',
            'archive': f'Dilated-{version}-macos-arm64.zip', 'dmg': f'Dilated-{version}-macos-arm64.dmg',
            'sourceArchive': f'Dilated-{version}-source.tar.gz',
            'notarizationStatus': 'Accepted', 'dmgNotarizationStatus': 'Accepted',
        }
        for key in publish.public.DISTRIBUTION_CHECKS:
            manifest[key] = True
        for prefix, field in [('archive', 'archive'), ('dmg', 'dmg'), ('source', 'sourceArchive')]:
            path = directory / manifest[field]
            path.write_bytes(f'{prefix} fixture {version}'.encode())
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest['sourceSHA256' if prefix == 'source' else prefix + 'SHA256'] = digest
            if prefix != 'source':
                manifest[prefix + 'Bytes'] = path.stat().st_size
        (directory / 'release-manifest.json').write_text(json.dumps(manifest))
        (self.assets / 'releases/latest.json').write_text(json.dumps({
            'released': True, 'version': version, 'build': build,
            'downloadURL': f"./releases/{version}/{manifest['dmg']}",
            'sha256': manifest['dmgSHA256'], 'prerelease': False, 'unverified': []}))
        return directory

    def write_feed(self, build):
        (self.assets / 'updates').mkdir(exist_ok=True)
        (self.assets / 'updates/appcast.xml').write_text(FEED.format(build=build))

    def deploys(self):
        return [call for call in self.calls if call[0] == 'vercel']

    def test_validation_only_checks_the_release_and_never_deploys(self):
        source, selected = publish.validate(self.repo, self.assets)
        self.assertEqual(selected['version'], VERSION)
        self.assertEqual(source, self.git('rev-parse', 'HEAD').strip())
        verify = [call for call in self.calls if call[0].endswith('sign_update')]
        self.assertEqual(len(verify), 1)
        self.assertEqual(verify[0][1:3], ['--account', 'com.codeswhat.dilated'])
        self.assertIn('--verify', verify[0])
        self.assertEqual(self.deploys(), [])

    def test_main_without_production_never_calls_vercel(self):
        original = publish.ROOT
        publish.ROOT = self.repo
        self.addCleanup(setattr, publish, 'ROOT', original)
        publish.main(['--public-dir', str(self.assets)])
        self.assertEqual(self.deploys(), [])

    def test_production_deploys_committed_site_with_retained_releases_and_feed(self):
        original = publish.ROOT
        publish.ROOT = self.repo
        self.addCleanup(setattr, publish, 'ROOT', original)
        seen = {}

        def fake_run(args, **kwargs):
            if args[0] in ('git', 'tar'):
                return real_run(args, **kwargs)
            if args[0] == 'vercel':
                deploy = Path(args[2])
                seen['files'] = sorted(str(path.relative_to(deploy)) for path in deploy.rglob('*') if path.is_file())
                seen['project'] = json.loads((deploy / '.vercel/project.json').read_text())
                seen['args'] = args
            return ''

        publish.run = fake_run
        publish.main(['--public-dir', str(self.assets), '--production'])
        self.assertIn('index.html', seen['files'])
        self.assertIn('vercel.json', seen['files'])
        self.assertIn('updates/appcast.xml', seen['files'])
        self.assertIn(f'releases/{VERSION}/Dilated-{VERSION}-macos-arm64.dmg', seen['files'])
        self.assertFalse(any(name.startswith('website/') for name in seen['files']))
        self.assertEqual(seen['project'], publish.VERCEL_PROJECT)
        self.assertEqual(seen['args'][3:], ['--prod', '--yes', '--scope', 'codeswhat', '--meta',
                                            f"sourceCommit={self.git('rev-parse', 'HEAD').strip()}",
                                            '--meta', 'sourceRepository=CodesWhat/dilated'])

    def test_only_committed_website_files_are_exported(self):
        (self.repo / 'website/dist/draft.html').write_text('uncommitted')
        (self.repo / 'secret.txt').write_text('private')
        self.git('add', 'secret.txt')
        self.git('commit', '-q', '-m', 'unrelated')
        source = self.git('rev-parse', 'HEAD').strip()
        staging = Path(self.temp.name) / 'staging'
        staging.mkdir()
        deploy = publish.build_staging(self.repo, source, self.assets, staging)
        names = {str(path.relative_to(deploy)) for path in deploy.rglob('*') if path.is_file()}
        self.assertNotIn('draft.html', names)
        self.assertNotIn('secret.txt', names)

    def test_redirects_must_describe_the_same_release_and_the_dmg(self):
        self.write_routes(VERSION, source='Dilated-0.9.0-source.tar.gz')
        self.commit()
        with self.assertRaisesRegex(RuntimeError, 'same release'):
            publish.validate(self.repo, self.assets)
        self.write_routes(VERSION, dmg=f'Dilated-{VERSION}-macos-arm64.zip')
        self.commit()
        with self.assertRaisesRegex(RuntimeError, 'advertised download'):
            publish.validate(self.repo, self.assets)

    def test_a_dirty_checkout_is_rejected(self):
        (self.repo / 'website/dist/index.html').write_text('edited')
        with self.assertRaisesRegex(RuntimeError, 'clean'):
            publish.validate(self.repo, self.assets)
        self.assertEqual(self.deploys(), [])

    def test_missing_or_changed_artifacts_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Retained'):
            publish.validate(self.repo, self.assets / 'nowhere')
        directory = self.assets / 'releases' / VERSION
        source = directory / f'Dilated-{VERSION}-source.tar.gz'
        source.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'source archive'):
            publish.validate(self.repo, self.assets)
        source.unlink()
        with self.assertRaisesRegex(RuntimeError, 'source archive'):
            publish.validate(self.repo, self.assets)
        (directory / f'Dilated-{VERSION}-macos-arm64.dmg').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'DMG checksum'):
            publish.validate(self.repo, self.assets)

    def test_latest_json_must_exist_and_describe_the_advertised_release(self):
        latest = self.assets / 'releases/latest.json'
        good = json.loads(latest.read_text())
        publish.validate(self.repo, self.assets)
        for change in [{'build': '3'}, {'sha256': '0' * 64}, {'version': '0.9.0'},
                       {'downloadURL': './releases/other.dmg'}, {'released': False},
                       {'prerelease': True}, {'unverified': ['helperCrashRecovery']}]:
            with self.subTest(change=change):
                latest.write_text(json.dumps({**good, **change}))
                with self.assertRaisesRegex(RuntimeError, 'latest.json'):
                    publish.validate(self.repo, self.assets)
        latest.write_text('not json')
        with self.assertRaisesRegex(RuntimeError, 'latest.json'):
            publish.validate(self.repo, self.assets)
        latest.unlink()
        with self.assertRaisesRegex(RuntimeError, 'latest.json'):
            publish.validate(self.repo, self.assets)

    def test_release_directory_must_match_its_manifest_version(self):
        (self.assets / 'releases' / VERSION).rename(self.assets / 'releases' / '9.9.9')
        with self.assertRaisesRegex(RuntimeError, 'directory name'):
            publish.validate(self.repo, self.assets)

    def test_the_feed_must_exist_and_advertise_the_newest_build(self):
        self.write_feed('3')
        with self.assertRaisesRegex(RuntimeError, 'newest build'):
            publish.validate(self.repo, self.assets)
        (self.assets / 'updates/appcast.xml').unlink()
        with self.assertRaisesRegex(RuntimeError, 'feed'):
            publish.validate(self.repo, self.assets)


if __name__ == '__main__':
    unittest.main()
