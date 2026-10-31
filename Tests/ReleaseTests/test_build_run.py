import os
import pathlib
import plistlib
import sys
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BuildRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dilated-build-run-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy(ROOT / 'scripts/build-app.sh', self.root / 'scripts/build-app.sh')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', CALLS=str(self.calls))
        self.stub('swift', 'echo swift >> "$CALLS"; exit 71')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts/build-app.sh'), *args],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=10)

    def test_unknown_options_fail_before_building(self):
        result = self.run_script('debug', '--unknown')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unknown option', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_logs_requires_verify(self):
        result = self.run_script('debug', '--logs')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--logs requires --verify', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_verify_refuses_custom_output_before_building(self):
        result = self.run_script('debug', '--verify', DILATED_BUILD_DIR='/Applications')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('build/Dilated.app', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_verify_prepares_only_the_running_dev_app_before_building(self):
        app = self.root / 'build/Dilated.app/Contents/MacOS'
        app.mkdir(parents=True)
        cli = app / 'dilated'
        cli.write_text('#!/bin/bash\necho prepare:$* >> "$CALLS"\n')
        cli.chmod(0o755)
        self.stub('ps', f'if [ ! -f "$CALLS" ]; then echo "123 {app}/DilatedApp"; fi')
        result = self.run_script('debug', '--verify')
        self.assertEqual(result.returncode, 71)
        self.assertEqual(self.calls.read_text().splitlines(), ['prepare:prepare-update', 'swift'])

    def test_failed_preparation_stops_before_building(self):
        app = self.root / 'build/Dilated.app/Contents/MacOS'
        app.mkdir(parents=True)
        cli = app / 'dilated'
        cli.write_text('#!/bin/bash\nexit 72\n')
        cli.chmod(0o755)
        self.stub('ps', f'echo "123 {app}/DilatedApp"')
        result = self.run_script('debug', '--verify')
        self.assertEqual(result.returncode, 72)
        self.assertFalse(self.calls.exists())

    def test_installed_app_blocks_verify_without_being_prepared(self):
        self.stub('ps', 'echo "123 /Applications/Dilated.app/Contents/MacOS/DilatedApp"')
        result = self.run_script('debug', '--verify')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another Dilated app', result.stderr)
        self.assertFalse(self.calls.exists())

    def successful_build_fixture(self):
        app = self.root / 'build/Dilated.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
        packaging = self.root / 'packaging'
        packaging.mkdir()
        shutil.copy(ROOT / 'packaging/Version.plist', packaging / 'Version.plist')
        (self.root / 'products/Dilated_DilatedUI.bundle').mkdir(parents=True)
        for name in ['cp', 'ditto', 'rm', 'codesign', 'plutil']:
            self.stub(name, 'exit 0')
        self.stub('python3', f'if [[ "$1" == "-" || "$1" == "-c" ]]; then exec "{sys.executable}" "$@"; fi')
        self.stub('git', 'echo 1234567890')
        self.stub('pgrep', 'exit 1')
        self.stub('swift', f'if [[ "$*" == *--show-bin-path* ]]; then echo "{self.root}/products"; fi')
        self.stub('open', 'echo "open:$*" >> "$CALLS"; touch "$CALLS.running"')
        self.stub('ps', f'if [[ -f "$CALLS.running" ]]; then echo "456 {app}/Contents/MacOS/DilatedApp"; fi')
        self.stub('log', 'echo "log:$*" >> "$CALLS"')

    def test_verify_launches_the_built_app_and_reports_its_pid(self):
        self.successful_build_fixture()
        result = self.run_script('debug', '--verify')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Running Dilated PID: 456', result.stdout)
        self.assertIn(f'open:-n {self.root}/build/Dilated.app', self.calls.read_text())
        self.assertNotIn('log:', self.calls.read_text())

    def test_logs_streams_only_after_verified_launch_with_a_deadline(self):
        self.successful_build_fixture()
        result = self.run_script('debug', '--verify', '--logs')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('log:stream --predicate process == "DilatedApp" --timeout 5m', self.calls.read_text())

    def test_verify_rejects_a_build_folder_symlink_to_another_location(self):
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        (self.root / 'build').symlink_to(elsewhere, target_is_directory=True)
        result = self.run_script('debug', '--verify')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
