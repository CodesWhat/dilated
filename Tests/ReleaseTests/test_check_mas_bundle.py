import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-mas-bundle.py'
spec = importlib.util.spec_from_file_location('check_mas_bundle', SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

BUNDLE_ID = 'com.codeswhat.dilated.appstore'
ARM64 = 0x0100000C
X86_64 = 0x01000007


def thin_macho(cpu=ARM64):
    return struct.pack('<IIIIIIII', 0xFEEDFACF, cpu, 0, 2, 0, 0, 0, 0) + b'\0' * 64


def fat_macho(*cpus):
    header = struct.pack('>II', 0xCAFEBABE, len(cpus))
    for cpu in cpus:
        header += struct.pack('>IIIII', cpu, 0, 4096, 64, 12)
    return header + b'\0' * 64


class CheckMasBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / 'Dilated.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        self.info = {
            'CFBundleIdentifier': BUNDLE_ID,
            'CFBundleExecutable': 'DilatedApp',
            'CFBundleVersion': '17',
            'CFBundleShortVersionString': '1.0.0',
            'LSApplicationCategoryType': 'public.app-category.utilities',
            'DilatedUpdatesEnabled': False,
        }
        self.entitlements = {
            'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.files.bookmarks.app-scope': True,
            'com.apple.security.application-groups': ['3524374A2S.com.codeswhat.dilated.controls'],
        }
        self.write_info()
        self.write_binary(self.app / 'Contents/MacOS/DilatedApp', thin_macho())
        (self.app / 'Contents/Resources/Dilated.sdef').write_text('<dictionary/>')
        control = self.app / 'Contents/PlugIns/DilatedControls.appex'
        control_info = dict(self.info, CFBundleIdentifier=BUNDLE_ID + '.controls',
                            CFBundleExecutable='DilatedControls', LSMinimumSystemVersion='26.0',
                            NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})
        (control / 'Contents').mkdir(parents=True)
        (control / 'Contents/Info.plist').write_bytes(plistlib.dumps(control_info))
        self.write_binary(control / 'Contents/MacOS/DilatedControls', thin_macho())
        action = {'supportedModes': 2, 'isDiscoverable': False,
                  'systemProtocols': ['com.apple.link.systemProtocol.SetValue'],
                  'parameters': [{'name': 'value', 'isOptional': False,
                                  'valueType': {'primitive': {'wrapper': {'typeIdentifier': 1}}}}]}
        for bundle in (self.app, control):
            metadata = bundle / 'Contents/Resources/Metadata.appintents'
            metadata.mkdir(parents=True, exist_ok=True)
            (metadata / 'extract.actionsdata').write_text(json.dumps({'actions': {'SetAwakeControlIntent': action}}))

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def write_binary(self, path, data, mode=0o755):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    def check(self):
        return checker.check_bundle(self.app, BUNDLE_ID, self.entitlements)

    def assert_fails_with(self, text):
        failures = self.check()
        self.assertTrue(any(text in failure for failure in failures), failures)

    def test_clean_fixture_passes(self):
        self.assertEqual(self.check(), [])

    def test_foreign_app_group_fails(self):
        self.entitlements['com.apple.security.application-groups'] = ['foreign']
        self.assert_fails_with('app group')

    def test_missing_control_executable_fails(self):
        (self.app / 'Contents/PlugIns/DilatedControls.appex/Contents/MacOS/DilatedControls').unlink()
        self.assert_fails_with('Control extension')

    def test_fat_arm64_only_slice_list_passes(self):
        self.write_binary(self.app / 'Contents/MacOS/DilatedApp', fat_macho(ARM64))
        self.assertEqual(self.check(), [])

    def test_planted_temporary_exception_entitlement_fails(self):
        self.entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = ['x']
        self.assert_fails_with('temporary-exception')

    def test_user_selected_read_write_entitlement_passes(self):
        self.entitlements['com.apple.security.files.user-selected.read-only'] = True
        self.entitlements['com.apple.security.files.user-selected.read-write'] = True
        self.assertEqual(self.check(), [])

    def test_unlisted_entitlement_fails(self):
        self.entitlements['com.apple.security.cs.allow-jit'] = True
        self.assert_fails_with('not in the MAS allowlist')

    def test_missing_sandbox_fails(self):
        del self.entitlements['com.apple.security.app-sandbox']
        self.assert_fails_with('app-sandbox must be true')

    def test_embedded_extra_executable_fails(self):
        self.write_binary(self.app / 'Contents/MacOS/dilated', thin_macho())
        self.assert_fails_with('Contents/MacOS/dilated: embedded executable')

    def test_embedded_script_with_exec_bit_fails(self):
        self.write_binary(self.app / 'Contents/Resources/run.sh', b'echo hi\n', mode=0o755)
        self.assert_fails_with('run.sh: embedded executable')

    def test_su_keys_fail(self):
        self.info['SUFeedURL'] = 'https://example.invalid/appcast.xml'
        self.write_info()
        self.assert_fails_with('SUFeedURL')

    def test_sparkle_framework_fails(self):
        self.write_binary(self.app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', thin_macho())
        self.assert_fails_with('Sparkle must not be in the bundle')

    def test_wrong_bundle_id_fails(self):
        self.info['CFBundleIdentifier'] = 'com.codeswhat.dilated'
        self.write_info()
        self.assert_fails_with('CFBundleIdentifier')

    def test_missing_category_fails(self):
        del self.info['LSApplicationCategoryType']
        self.write_info()
        self.assert_fails_with('LSApplicationCategoryType')

    def test_launch_daemon_plist_fails(self):
        daemon = self.app / 'Contents/Library/LaunchDaemons/com.example.helper.plist'
        daemon.parent.mkdir(parents=True)
        daemon.write_bytes(plistlib.dumps({'Label': 'com.example.helper', 'BundleProgram': 'Contents/MacOS/x'}))
        self.assert_fails_with('daemon or LaunchAgent plist')

    def test_launch_agent_plist_outside_known_folder_fails(self):
        agent = self.app / 'Contents/Resources/repair.plist'
        agent.write_bytes(plistlib.dumps({'Label': 'com.example.repair', 'ProgramArguments': ['/bin/true']}))
        self.assert_fails_with('daemon or LaunchAgent plist')

    def test_x86_64_binary_fails(self):
        self.write_binary(self.app / 'Contents/MacOS/DilatedApp', fat_macho(ARM64, X86_64))
        self.assert_fails_with('expected arm64 only')

    def test_cli_exit_codes_and_messages(self):
        entitlements = Path(self.tmp.name) / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(self.entitlements))

        def run():
            return subprocess.run(
                [sys.executable, '-I', str(SCRIPT), str(self.app), '--entitlements', str(entitlements)],
                capture_output=True, text=True)

        clean = run()
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.entitlements['com.apple.security.temporary-exception.files.home-relative-path.read-write'] = ['/']
        entitlements.write_bytes(plistlib.dumps(self.entitlements))
        planted = run()
        self.assertEqual(planted.returncode, 1)
        self.assertIn('temporary-exception', planted.stderr)


if __name__ == '__main__':
    unittest.main()
