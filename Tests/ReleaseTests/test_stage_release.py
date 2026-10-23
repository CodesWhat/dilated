import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/stage-public-release.py'
spec = importlib.util.spec_from_file_location('stage_release', SCRIPT)
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class PublicationGuardsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dilated-publish-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        version = '1.0.0-beta.1'
        self.manifest = {
            'version': version, 'build': '2', 'candidate': False, 'tag': f'v{version}',
            'sourceRevision': 'a' * 40, 'architecture': 'arm64', 'minimumMacOS': '26.0',
            'archive': f'Dilated-{version}-macos-arm64.zip',
            'dmg': f'Dilated-{version}-macos-arm64.dmg',
            'notarizationStatus': 'Accepted', 'dmgNotarizationStatus': 'Accepted',
        }
        for key in stage.DISTRIBUTION_CHECKS:
            self.manifest[key] = True
        for prefix, field in [('archive', 'archive'), ('dmg', 'dmg')]:
            path = self.root / self.manifest[field]
            path.write_bytes(f'{prefix} release fixture'.encode())
            self.manifest[prefix + 'SHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            self.manifest[prefix + 'Bytes'] = path.stat().st_size
        self.save()

    def save(self):
        (self.root / 'release-manifest.json').write_text(json.dumps(self.manifest))

    def acceptance(self):
        return {
            key: self.manifest[key]
            for key in ['version', 'build', 'sourceRevision', 'archiveSHA256', 'dmgSHA256']
        } | {'checks': {
            key: {'status': 'passed', 'machine': 'second-mac' if key in ['macOS27ClosedLid', 'cleanInstallSecondMac'] else 'primary-mac',
                  'macOS': '27.0' if key == 'macOS27ClosedLid' else '26.6.2',
                  'evidence': 'Automated publication fixture, not hardware evidence.'}
            for key in stage.ACCEPTANCE_CHECKS
        }}

    def test_only_checked_tagged_release_artifacts_can_be_staged(self):
        self.assertEqual(stage.validate_archive(self.root), self.manifest)
        for field, value in [('candidate', True), ('tag', None), ('updatesEnabled', False), ('notarizationStatus', 'Invalid'), ('dmgGatekeeperAccepted', False), ('architecture', 'x86_64')]:
            with self.subTest(field=field):
                original = self.manifest[field]
                self.manifest[field] = value
                self.save()
                with self.assertRaises(RuntimeError):
                    stage.validate_archive(self.root)
                self.manifest[field] = original

    def test_changed_bytes_or_unsafe_version_cannot_be_published(self):
        (self.root / self.manifest['archive']).write_bytes(b'changed after checking')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            stage.validate_archive(self.root)
        self.manifest['version'] = '../escape'
        self.save()
        with self.assertRaisesRegex(RuntimeError, 'version'):
            stage.validate_archive(self.root)

    def test_acceptance_must_cover_exact_artifacts_both_systems_and_another_mac(self):
        record = self.acceptance()
        stage.validate_acceptance(record, self.manifest)
        for field in ['archiveSHA256', 'sourceRevision', 'build']:
            invalid = self.acceptance()
            invalid[field] = 'different'
            with self.assertRaisesRegex(RuntimeError, 'match'):
                stage.validate_acceptance(invalid, self.manifest)
        for check in stage.ACCEPTANCE_CHECKS:
            invalid = self.acceptance()
            invalid['checks'][check]['status'] = 'pending'
            with self.assertRaisesRegex(RuntimeError, 'acceptance'):
                stage.validate_acceptance(invalid, self.manifest)
        record['checks']['macOS27ClosedLid']['macOS'] = '26.6.2'
        with self.assertRaisesRegex(RuntimeError, 'macOS 27'):
            stage.validate_acceptance(record, self.manifest)
        record = self.acceptance()
        record['checks']['cleanInstallSecondMac']['machine'] = 'primary-mac'
        with self.assertRaisesRegex(RuntimeError, 'second Mac'):
            stage.validate_acceptance(record, self.manifest)

    def test_latest_metadata_uses_the_accepted_dmg(self):
        latest = stage.latest_metadata(self.manifest)
        self.assertTrue(latest['released'])
        self.assertEqual(latest['downloadURL'], './releases/1.0.0-beta.1/' + self.manifest['dmg'])
        self.assertEqual(latest['sha256'], self.manifest['dmgSHA256'])

    def test_a_failed_immutable_asset_check_cannot_change_the_feed_or_latest(self):
        staged = self.root / 'staged'
        retained = self.root / 'retained'
        for base, content in [(staged, b'new'), (retained, b'original')]:
            (base / 'updates').mkdir(parents=True)
            (base / 'releases/1.0.0').mkdir(parents=True)
            (base / 'updates/appcast.xml').write_bytes(content)
            (base / 'releases/latest.json').write_bytes(content)
            (base / 'releases/1.0.0/Dilated.dmg').write_bytes(content)
        with self.assertRaisesRegex(RuntimeError, 'immutable'):
            stage.retain_public_assets(staged, retained)
        self.assertEqual((retained / 'updates/appcast.xml').read_bytes(), b'original')
        self.assertEqual((retained / 'releases/latest.json').read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
