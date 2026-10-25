import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/normalize-resource-bundle.py'
spec = importlib.util.spec_from_file_location('normalize_resource_bundle', SCRIPT)
normalize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(normalize)


class ResourceBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bundle = Path(self.tmp.name) / 'Dilated_DilatedUI.bundle'
        self.bundle.mkdir()

    def populate_flat(self):
        (self.bundle / 'MenuBar').mkdir()
        (self.bundle / 'MenuBar/icon.png').write_bytes(b'png')
        (self.bundle / 'Fonts').mkdir()
        (self.bundle / 'Sounds').mkdir()

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.bundle)], capture_output=True, text=True
        )

    def snapshot(self):
        return sorted(str(p.relative_to(self.bundle)) for p in self.bundle.rglob('*'))

    def assert_layout(self):
        self.assertTrue((self.bundle / 'Contents/Info.plist').is_file())
        self.assertFalse((self.bundle / 'Info.plist').exists())
        for name in ('MenuBar', 'Fonts', 'Sounds'):
            self.assertTrue((self.bundle / 'Contents/Resources' / name).is_dir())
            self.assertFalse((self.bundle / name).exists())
        self.assertEqual((self.bundle / 'Contents/Resources/MenuBar/icon.png').read_bytes(), b'png')

    def test_proper_bundle_is_untouched(self):
        (self.bundle / 'Contents/Resources/MenuBar').mkdir(parents=True)
        (self.bundle / 'Contents/Resources/MenuBar/icon.png').write_bytes(b'png')
        (self.bundle / 'Contents/Resources/Fonts').mkdir()
        (self.bundle / 'Contents/Resources/Sounds').mkdir()
        plist = plistlib.dumps({'CFBundleName': 'original'})
        (self.bundle / 'Contents/Info.plist').write_bytes(plist)
        before = self.snapshot()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.bundle / 'Contents/Info.plist').read_bytes(), plist)

    def test_flat_bundle_with_plist(self):
        self.populate_flat()
        plist = plistlib.dumps({'CFBundleName': 'flat'})
        (self.bundle / 'Info.plist').write_bytes(plist)
        self.assertEqual(self.run_script().returncode, 0)
        self.assert_layout()
        self.assertEqual((self.bundle / 'Contents/Info.plist').read_bytes(), plist)

    def test_flat_bundle_without_plist_gets_minimal_plist(self):
        self.populate_flat()
        self.assertEqual(self.run_script().returncode, 0)
        self.assert_layout()
        info = plistlib.loads((self.bundle / 'Contents/Info.plist').read_bytes())
        version = plistlib.loads((ROOT / 'packaging/Version.plist').read_bytes())
        self.assertEqual(
            info,
            {
                'CFBundleIdentifier': 'com.codeswhat.dilated.DilatedUI.resources',
                'CFBundleName': 'Dilated_DilatedUI',
                'CFBundlePackageType': 'BNDL',
                'CFBundleInfoDictionaryVersion': '6.0',
                'CFBundleShortVersionString': version['CFBundleShortVersionString'],
                'CFBundleVersion': version['CFBundleVersion'],
            },
        )

    def test_idempotent(self):
        self.populate_flat()
        self.assertEqual(self.run_script().returncode, 0)
        before = self.snapshot()
        plist = (self.bundle / 'Contents/Info.plist').read_bytes()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((self.bundle / 'Contents/Info.plist').read_bytes(), plist)

    def test_non_directory_fails(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.bundle / 'missing')],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a directory', result.stderr)


if __name__ == '__main__':
    unittest.main()
