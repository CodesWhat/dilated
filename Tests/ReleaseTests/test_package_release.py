import hashlib
import importlib.util
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/package-release.py'
spec = importlib.util.spec_from_file_location('package_release', SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseGuardsTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Archive integration requires macOS ditto")
    def test_update_zip_places_only_the_app_at_the_archive_root(self):
        app = self.root / 'Dilated.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(b'fixture app metadata')
        archive = self.root / 'update.zip'
        release.create_update_archive(app, archive)
        with zipfile.ZipFile(archive) as zipped:
            paths = [name for name in zipped.namelist() if not name.startswith('__MACOSX/')]
            self.assertTrue(paths)
            self.assertTrue(all(name.startswith('Dilated.app/') for name in paths), paths)
            self.assertEqual(zipped.read('Dilated.app/Contents/Info.plist'), b'fixture app metadata')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dilated-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        (self.root / '.gitignore').write_text('.planning/\n.claude/\n')
        self.git('add', '.gitignore')
        (self.root / 'source.txt').write_text('reviewed source\n')
        self.git('add', 'source.txt')
        self.git('commit', '-qm', 'initial fixture')
        self.git('tag', 'v0.1.0-alpha.1')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def test_exact_clean_tag_is_accepted(self):
        self.assertEqual(release.verify_source(self.root, '0.1.0-alpha.1'), self.git('rev-parse', 'HEAD'))

    def test_local_candidate_uses_clean_source_without_a_release_tag(self):
        self.assertEqual(release.verify_source(self.root, '1.0.0-beta.1', candidate=True), self.git('rev-parse', 'HEAD'))
        (self.root / 'unreviewed.txt').write_text('unfinished change')
        with self.assertRaisesRegex(RuntimeError, 'clean'):
            release.verify_source(self.root, '1.0.0-beta.1', candidate=True)

    @unittest.skipUnless(sys.platform == "darwin", "Signed bundle integration requires macOS")
    def test_packager_builds_into_its_own_output_with_canonical_metadata_and_helper(self):
        output = self.root / 'bundle output'
        release.build_app(SCRIPT.parents[1], output, '-', enable_updates=True)
        app = output / 'Dilated.app'
        with (app / 'Contents/Info.plist').open('rb') as file:
            info = plistlib.load(file)
        metadata = release.release_metadata(SCRIPT.parents[1])
        self.assertEqual(info['DilatedDisplayVersion'], metadata['DilatedDisplayVersion'])
        self.assertEqual(info['CFBundleVersion'], metadata['CFBundleVersion'])
        self.assertEqual(info['CFBundleIdentifier'], 'com.codeswhat.dilated')
        self.assertIn('Wi-Fi', info['NSLocationUsageDescription'])
        self.assertIn('paired devices', info['NSBluetoothAlwaysUsageDescription'])
        signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                capture_output=True, check=True)
        entitlements = plistlib.loads(signed.stdout)
        self.assertTrue(entitlements['com.apple.security.personal-information.location'])
        self.assertNotIn('com.apple.wifi.events', entitlements)
        for binary in ['dilated', 'dilated-helper']:
            signed_child = subprocess.run(
                ['codesign', '-d', '--entitlements', ':-', str(app / 'Contents/MacOS' / binary)],
                capture_output=True, check=True)
            self.assertNotIn(b'com.apple.wifi.events', signed_child.stdout)
            self.assertNotIn(b'com.apple.security.personal-information.location', signed_child.stdout)
        self.assertEqual(len(info['DilatedSourceRevision']), 40)
        framework = app / 'Contents/Frameworks/Sparkle.framework'
        self.assertTrue((framework / 'Versions/B/Sparkle').is_file())
        self.assertTrue((app / 'Contents/Resources/Sparkle-LICENSE').is_file())
        self.assertEqual(info['SUPublicEDKey'], 'ehOxBirzN5y9MqUzYKsrYwgn4MAle82Z3rQIvYpZlhY=')
        self.assertEqual(info['SUFeedURL'], 'https://dilated.codeswhat.com/updates/appcast.xml')
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertTrue(info['DilatedUpdatesEnabled'])
        release.validate_automation_bundle(app)
        import json
        actions = json.loads((app / 'Contents/Resources/Metadata.appintents/extract.actionsdata').read_bytes())['actions']
        display = next(item for item in actions['StartAwakeIntent']['parameters'] if item['name'] == 'allowDisplaySleep')
        self.assertFalse(display['isOptional'])
        self.assertEqual(display['typeSpecificMetadata'], [
            'LNValueTypeSpecificMetadataKeyDefaultValue', {'int': {'wrapper': 1}}])
        linked = subprocess.check_output(['otool', '-L', str(app / 'Contents/MacOS/DilatedApp')], text=True)
        self.assertIn('@rpath/Sparkle.framework', linked)
        for binary in ['dilated', 'dilated-helper']:
            linked = subprocess.check_output(['otool', '-L', str(app / 'Contents/MacOS' / binary)], text=True)
            self.assertNotIn('Sparkle', linked)
        with (app / 'Contents/Library/LaunchDaemons/com.codeswhat.dilated.helper.plist').open('rb') as file:
            helper = plistlib.load(file)
        self.assertEqual(helper['BundleProgram'], 'Contents/MacOS/dilated-helper')
        self.assertTrue(helper['KeepAlive'])
        self.assertEqual(release.validate_helper_bundle(app), app / helper['BundleProgram'])
        probe = subprocess.check_output([str(app / helper['BundleProgram']), '--inspect'], text=True)
        self.assertEqual(json.loads(probe)['protocolVersion'], 1)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        import os
        state = self.root / 'launch-state'
        state.mkdir()
        (state / 'settings.json').write_text('{"onboardingComplete":true}')
        environment = dict(os.environ, DILATED_STATE_DIR=str(state))
        process = subprocess.Popen([str(app / 'Contents/MacOS/DilatedApp')], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and process.poll() is None:
                result = subprocess.run([str(app / 'Contents/MacOS/dilated'), 'status', '--json'],
                                        env=environment, capture_output=True, text=True, timeout=4)
                if result.returncode == 0:
                    self.assertTrue(json.loads(result.stdout)['ok'])
                    break
                time.sleep(0.1)
            else:
                error = process.stderr.read() if process.poll() is not None else 'App did not start its control connection'
                self.fail(error or f'App exited with status {process.poll()} before starting control')
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)
            digest = hashlib.sha256(str(state).encode()).hexdigest()[:16]
            socket_directory = pathlib.Path(f'/tmp/com.codeswhat.dilated-{os.getuid()}-{digest}')
            if socket_directory.exists():
                (socket_directory / 'control.sock').unlink(missing_ok=True)
                socket_directory.rmdir()
        release.verify_requirement(app, 'identifier "com.codeswhat.dilated"')
        with self.assertRaises(RuntimeError):
            release.verify_requirement(app, 'identifier "com.codeswhat.other"')

    def test_missing_automation_metadata_cannot_ship(self):
        app = self.root / 'Dilated.app'
        folder = app / 'Contents'
        folder.mkdir(parents=True)
        with (folder / 'Info.plist').open('wb') as file:
            plistlib.dump({'NSAppleScriptEnabled': True, 'OSAScriptingDefinition': 'Dilated.sdef'}, file)
        with self.assertRaisesRegex(RuntimeError, 'automation'):
            release.validate_automation_bundle(app)

    def test_a_mispackaged_helper_cannot_reach_notarization(self):
        app = self.root / 'Dilated.app'
        folder = app / 'Contents/Library/LaunchDaemons'
        folder.mkdir(parents=True)
        helper = app / 'Contents/MacOS/dilated-helper'
        helper.parent.mkdir(parents=True)
        helper.write_text('fixture')
        helper.chmod(0o755)
        correct = {'Label': 'com.codeswhat.dilated.helper',
                   'BundleProgram': 'Contents/MacOS/dilated-helper',
                   'MachServices': {'com.codeswhat.dilated.helper': True},
                   'UserName': 'root', 'RunAtLoad': True, 'KeepAlive': True}
        for key, value in [('Label', 'other'), ('BundleProgram', '/tmp/other'),
                           ('RunAtLoad', False), ('KeepAlive', False), ('UserName', 'nobody')]:
            with self.subTest(key=key):
                with (folder / 'com.codeswhat.dilated.helper.plist').open('wb') as file:
                    plistlib.dump({**correct, key: value}, file)
                with self.assertRaisesRegex(RuntimeError, 'helper'):
                    release.validate_helper_bundle(app)

    def test_dirty_tracked_or_untracked_source_cannot_ship(self):
        for name in ['source.txt', 'unreviewed.txt']:
            with self.subTest(name=name):
                path = self.root / name
                path.write_text('unreviewed change\n')
                with self.assertRaisesRegex(RuntimeError, 'clean'):
                    release.verify_source(self.root, '0.1.0-alpha.1')
                if name == 'source.txt':
                    self.git('restore', name)
                else:
                    path.unlink()

    def test_a_commit_after_the_tag_cannot_ship_under_that_version(self):
        (self.root / 'source.txt').write_text('later source\n')
        self.git('commit', '-qam', 'later fixture')
        with self.assertRaisesRegex(RuntimeError, 'tag'):
            release.verify_source(self.root, '0.1.0-alpha.1')

    def test_stable_version_without_prerelease_suffix_is_accepted(self):
        (self.root / 'packaging').mkdir()
        metadata = {'DilatedDisplayVersion': '0.1.0', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '15'}
        with (self.root / 'packaging/Version.plist').open('wb') as file:
            plistlib.dump(metadata, file)
        self.assertEqual(release.release_metadata(self.root)['DilatedDisplayVersion'], '0.1.0')

    def test_invalid_or_inconsistent_bundle_metadata_is_rejected(self):
        (self.root / 'packaging').mkdir()
        metadata = {'DilatedDisplayVersion': '0.1.0-alpha.1', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1'}
        path = self.root / 'packaging/Version.plist'
        for key, value in [('CFBundleShortVersionString', '0.2.0'), ('CFBundleVersion', '0'), ('DilatedDisplayVersion', '0.1.0-alpha.0')]:
            with self.subTest(key=key):
                with path.open('wb') as file:
                    plistlib.dump({**metadata, key: value}, file)
                with self.assertRaises(RuntimeError):
                    release.release_metadata(self.root)

    def test_the_existing_release_directory_is_never_reused(self):
        output = self.root / 'output'
        existing = output / '0.1.0-alpha.1'
        existing.mkdir(parents=True)
        marker = existing / 'keep.txt'
        marker.write_text('preserve this artifact')
        with self.assertRaises(FileExistsError):
            release.create_output(output, '0.1.0-alpha.1')
        self.assertEqual(marker.read_text(), 'preserve this artifact')


class NotaryAuthTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.directory = pathlib.Path(self._temp.name)

    def store(self, config, key_id=None):
        (self.directory / 'config.env').write_text(config)
        if key_id:
            (self.directory / 'private_keys').mkdir(exist_ok=True)
            (self.directory / 'private_keys' / f'AuthKey_{key_id}.p8').write_text('fake key')

    def test_api_key_is_the_default_when_the_key_file_exists(self):
        self.store('# comment\nexport ASC_KEY_ID=FAKEKEY123\nexport ASC_ISSUER_ID="fake-issuer-id"\n', 'FAKEKEY123')
        self.assertEqual(release.notary_auth(None, self.directory), [
            '--key', str(self.directory / 'private_keys/AuthKey_FAKEKEY123.p8'),
            '--key-id', 'FAKEKEY123', '--issuer', 'fake-issuer-id'])

    def test_keychain_profile_overrides_the_api_key(self):
        self.store('ASC_KEY_ID=FAKEKEY123\nASC_ISSUER_ID=fake-issuer-id\n', 'FAKEKEY123')
        self.assertEqual(release.notary_auth('some-profile', self.directory), ['--keychain-profile', 'some-profile'])

    def test_missing_key_file_or_config_is_rejected_without_a_profile(self):
        self.store('ASC_KEY_ID=FAKEKEY123\nASC_ISSUER_ID=fake-issuer-id\n')
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory)
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory / 'absent')

    def test_incomplete_config_is_rejected(self):
        self.store('ASC_KEY_ID=FAKEKEY123\n', 'FAKEKEY123')
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory)


if __name__ == '__main__':
    unittest.main()
