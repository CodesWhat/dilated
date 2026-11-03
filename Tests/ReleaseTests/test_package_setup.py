import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/package-setup.py'
spec = importlib.util.spec_from_file_location('package_setup', SCRIPT)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

METADATA = {'DilatedDisplayVersion': '1.2.3-beta.4', 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '42'}


class PackageSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dilated-setup-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def fixture_bundle(self):
        bundle = self.root / 'built' / setup.RESOURCE_BUNDLE
        (bundle / 'Contents/Resources').mkdir(parents=True)
        (bundle / 'Contents/Resources/dilated-power').write_text('#!/bin/bash\n')
        (bundle / 'Contents/Resources/agent.plist').write_text('<plist/>')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'checkout-path.resources'}))
        executable = self.root / 'built' / setup.EXECUTABLE
        executable.write_text('binary')
        return executable, bundle

    def test_info_plist_carries_identity_version_and_minimum_system(self):
        info = setup.setup_info(METADATA, 'a' * 40, '26.0')
        self.assertEqual(info['CFBundleIdentifier'], 'com.codeswhat.dilated.closed-lid-setup')
        self.assertEqual(info['CFBundleExecutable'], 'DilatedSetup')
        self.assertEqual(info['CFBundlePackageType'], 'APPL')
        self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')
        self.assertEqual(info['CFBundleVersion'], '42')
        self.assertEqual(info['DilatedDisplayVersion'], '1.2.3-beta.4')
        self.assertEqual(info['DilatedSourceRevision'], 'a' * 40)
        self.assertEqual(info['LSMinimumSystemVersion'], '26.0')
        self.assertNotIn('LSUIElement', info)

    def test_minimum_system_matches_the_main_app(self):
        with (setup.ROOT / 'packaging/Info.plist').open('rb') as file:
            main_app = plistlib.load(file)['LSMinimumSystemVersion']
        self.assertEqual(setup.minimum_system_version(setup.ROOT), main_app)

    def test_layout_puts_the_resource_bundle_where_bundle_module_looks(self):
        executable, bundle = self.fixture_bundle()
        app = self.root / 'out' / f'{setup.APP_NAME}.app'
        setup.assemble_app(app, executable, bundle, setup.setup_info(METADATA, 'b' * 40, '26.0'))
        self.assertEqual((app / 'Contents/MacOS/DilatedSetup').read_text(), 'binary')
        nested = app / 'Contents/Resources' / setup.RESOURCE_BUNDLE
        self.assertEqual((nested / 'Contents/Resources/dilated-power').read_text(), '#!/bin/bash\n')
        self.assertTrue((nested / 'Contents/Resources/agent.plist').is_file())
        with (app / 'Contents/Info.plist').open('rb') as file:
            self.assertEqual(plistlib.load(file)['CFBundleIdentifier'], setup.BUNDLE_ID)
        with (nested / 'Contents/Info.plist').open('rb') as file:
            self.assertEqual(plistlib.load(file)['CFBundleIdentifier'], setup.RESOURCE_BUNDLE_ID)

    def test_a_flat_resource_bundle_is_normalized(self):
        flat = self.root / 'flat' / setup.RESOURCE_BUNDLE
        flat.mkdir(parents=True)
        (flat / 'dilated-power').write_text('script')
        (flat / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'x'}))
        executable = self.root / 'flat' / setup.EXECUTABLE
        executable.write_text('binary')
        app = self.root / 'out' / f'{setup.APP_NAME}.app'
        setup.assemble_app(app, executable, flat, {'CFBundleIdentifier': setup.BUNDLE_ID})
        nested = app / 'Contents/Resources' / setup.RESOURCE_BUNDLE
        self.assertEqual((nested / 'Contents/Resources/dilated-power').read_text(), 'script')
        self.assertFalse((nested / 'dilated-power').exists())

    def test_signing_runs_inside_out_with_hardened_runtime_timestamp_and_no_entitlements(self):
        app = self.root / f'{setup.APP_NAME}.app'
        commands = setup.sign_commands(app, 'Developer ID Application: Test (TEAM)')
        targets = [command[-1] for command in commands]
        self.assertEqual(targets, [str(app / 'Contents/Resources' / setup.RESOURCE_BUNDLE),
                                   str(app / 'Contents/MacOS/DilatedSetup'), str(app)])
        for command in commands:
            self.assertIn('--timestamp', command)
            self.assertEqual(command[command.index('--options') + 1], 'runtime')
            self.assertEqual(command[command.index('--sign') + 1], 'Developer ID Application: Test (TEAM)')
            self.assertNotIn('--entitlements', command)

    def test_sign_app_issues_each_command_through_the_shared_runner(self):
        app = self.root / f'{setup.APP_NAME}.app'
        calls = []
        unsigned = mock.Mock(stderr='', returncode=0)
        with mock.patch.object(setup.release, 'run', side_effect=lambda args, **kw: calls.append(args) or ''), \
                mock.patch.object(setup.subprocess, 'run', return_value=unsigned):
            with self.assertRaisesRegex(RuntimeError, 'Developer ID'):
                setup.sign_app(app, 'id')
        self.assertEqual([call[0] for call in calls], ['codesign'] * 4)
        self.assertEqual(calls[-1][1:4], ['--verify', '--deep', '--strict'])

    def test_expected_script_hash_is_read_from_the_sources(self):
        digest = setup.expected_script_sha256(setup.ROOT)
        self.assertRegex(digest, r'^[0-9a-f]{64}$')

    def test_runtime_check_rejects_a_hash_mismatch(self):
        app = self.root / f'{setup.APP_NAME}.app'
        script = app / 'Contents/Resources' / setup.RESOURCE_BUNDLE / 'Contents/Resources/dilated-power'
        script.parent.mkdir(parents=True)
        script.write_text('tampered')
        report = '{"scriptMatches": true, "plistValid": true, "scriptSHA256": "%s"}' % ('0' * 64)
        with mock.patch.object(setup.release, 'run', return_value=report):
            with self.assertRaisesRegex(RuntimeError, 'do not resolve or match'):
                setup.check_packaged_app(app)


if __name__ == '__main__':
    unittest.main()
