import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('bundle_metadata', ROOT / 'scripts/bundle-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class StampTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'packaging').mkdir()
        self.write_version({'MASBundleVersion': '18'})
        self.app_info = self.root / 'Dilated.app/Contents/Info.plist'
        self.extension_info = self.root / 'Dilated.app/Contents/PlugIns/DilatedControls.appex/Contents/Info.plist'
        for path in (self.app_info, self.extension_info):
            path.parent.mkdir(parents=True)
            path.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'x'}))
        cwd = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, cwd)

    def write_version(self, extra):
        data = {'DilatedDisplayVersion': '1.1.0', 'CFBundleShortVersionString': '1.1.0',
                'CFBundleVersion': '21', **extra}
        (self.root / 'packaging/Version.plist').write_bytes(plistlib.dumps(data))

    def stamp(self, mas=False):
        with mock.patch.object(metadata.subprocess, 'check_output', return_value='abc123\n'):
            metadata.stamp(self.app_info, True, None, mas)
        return plistlib.loads(self.app_info.read_bytes()), plistlib.loads(self.extension_info.read_bytes())

    def test_direct_stamp_keeps_the_direct_build_and_drops_the_mas_counter(self):
        info, extension = self.stamp()
        self.assertEqual(info['CFBundleVersion'], '21')
        self.assertEqual(extension['CFBundleVersion'], '21')
        self.assertNotIn('MASBundleVersion', info)

    def test_mas_stamp_uses_the_mas_counter_for_both_bundles(self):
        info, extension = self.stamp(mas=True)
        self.assertEqual(info['CFBundleVersion'], '18')
        self.assertEqual(extension['CFBundleVersion'], '18')
        self.assertEqual(info['CFBundleShortVersionString'], '1.1.0')
        self.assertNotIn('MASBundleVersion', info)

    def test_mas_stamp_rejects_a_missing_or_invalid_counter(self):
        for extra in ({}, {'MASBundleVersion': '0'}, {'MASBundleVersion': 'x'}):
            with self.subTest(extra=extra):
                self.write_version(extra)
                with self.assertRaises(SystemExit):
                    self.stamp(mas=True)


if __name__ == '__main__':
    unittest.main()
