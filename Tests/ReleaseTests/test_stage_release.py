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
            key: {'status': 'passed', 'machine': 'primary-mac',
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

    def test_acceptance_must_cover_exact_artifacts_both_systems(self):
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

    def test_a_ga_record_from_a_single_machine_is_accepted_and_a_leftover_second_mac_entry_is_ignored(self):
        record = self.acceptance()
        self.assertEqual({check['machine'] for check in record['checks'].values()}, {'primary-mac'})
        summary = stage.validate_acceptance(record, self.manifest)
        self.assertEqual(summary['passed'], list(stage.ACCEPTANCE_CHECKS))
        record['checks']['cleanInstallSecondMac'] = {
            'status': 'passed', 'machine': 'primary-mac', 'macOS': '26.6.2', 'evidence': 'Leftover.'}
        self.assertEqual(stage.validate_acceptance(record, self.manifest), summary)

    def beta_acceptance(self):
        record = self.acceptance()
        for key, check in record['checks'].items():
            if key not in stage.PRERELEASE_REQUIRED_CHECKS:
                check['status'] = 'notRun'
                check['evidence'] = 'Not run for this beta.'
        record['checks']['helperCrashRecovery']['status'] = 'failed'
        return record

    def use_ga_version(self):
        self.manifest['version'] = '1.0.0'
        self.save()

    def test_a_prerelease_accepts_the_required_checks_and_names_the_rest(self):
        summary = stage.validate_acceptance(self.beta_acceptance(), self.manifest)
        required = list(stage.PRERELEASE_REQUIRED_CHECKS)
        self.assertTrue(summary['prerelease'])
        self.assertEqual(summary['passed'], [key for key in stage.ACCEPTANCE_CHECKS if key in required])
        self.assertEqual(summary['failed'], ['helperCrashRecovery'])
        self.assertEqual(summary['notRun'], [
            key for key in stage.ACCEPTANCE_CHECKS if key not in required and key != 'helperCrashRecovery'])
        full = stage.validate_acceptance(self.acceptance(), self.manifest)
        self.assertEqual(full, {'prerelease': True, 'passed': list(stage.ACCEPTANCE_CHECKS), 'failed': [], 'notRun': []})

    def test_a_prerelease_record_cannot_omit_or_skimp_on_any_check(self):
        def without_key(record):
            del record['checks']['rebootRecovery']

        def pending(record):
            record['checks']['rebootRecovery']['status'] = 'pending'

        def empty_evidence(record):
            record['checks']['rebootRecovery']['evidence'] = '  '

        def passed_without_machine(record):
            record['checks']['heartbeatExpiry'].pop('machine')

        def passed_without_macos(record):
            record['checks']['heartbeatExpiry']['macOS'] = ''

        def required_not_run(record):
            record['checks']['stopResume']['status'] = 'notRun'

        def required_failed(record):
            record['checks']['heartbeatExpiry']['status'] = 'failed'

        for mutate in [without_key, pending, empty_evidence, passed_without_machine,
                       passed_without_macos, required_not_run, required_failed]:
            with self.subTest(mutate=mutate.__name__):
                record = self.beta_acceptance()
                mutate(record)
                with self.assertRaisesRegex(RuntimeError, 'acceptance'):
                    stage.validate_acceptance(record, self.manifest)

    def test_a_prerelease_still_applies_the_macos_27_rule_when_passed(self):
        record = self.beta_acceptance()
        record['checks']['macOS27ClosedLid'] = {
            'status': 'passed', 'machine': 'second-mac', 'macOS': '26.6.2', 'evidence': 'Fixture.'}
        with self.assertRaisesRegex(RuntimeError, 'macOS 27'):
            stage.validate_acceptance(record, self.manifest)
        record = self.beta_acceptance()
        record['checks']['macOS27ClosedLid']['macOS'] = '26.6.2'
        stage.validate_acceptance(record, self.manifest)

    def test_the_macos_26_lid_check_must_run_on_macos_26(self):
        record = self.beta_acceptance()
        record['checks']['macOS26ClosedLid']['macOS'] = '27.0'
        with self.assertRaisesRegex(RuntimeError, 'macOS 26'):
            stage.validate_acceptance(record, self.manifest)
        self.use_ga_version()
        record = self.acceptance()
        record['version'] = '1.0.0'
        record['checks']['macOS26ClosedLid']['macOS'] = '27.0'
        with self.assertRaisesRegex(RuntimeError, 'macOS 26'):
            stage.validate_acceptance(record, self.manifest)

    def test_a_prerelease_still_matches_the_exact_artifacts(self):
        record = self.beta_acceptance()
        record['dmgSHA256'] = 'different'
        with self.assertRaisesRegex(RuntimeError, 'match'):
            stage.validate_acceptance(record, self.manifest)

    def test_a_ga_version_keeps_the_full_gate(self):
        self.use_ga_version()
        summary = stage.validate_acceptance(self.acceptance(), self.manifest)
        self.assertEqual(summary, {'prerelease': False, 'passed': list(stage.ACCEPTANCE_CHECKS), 'failed': [], 'notRun': []})
        with self.assertRaisesRegex(RuntimeError, 'acceptance'):
            stage.validate_acceptance(self.beta_acceptance(), self.manifest)
        partial = self.acceptance()
        del partial['checks']['nativeUI']
        with self.assertRaisesRegex(RuntimeError, 'acceptance'):
            stage.validate_acceptance(partial, self.manifest)

    def test_latest_metadata_names_the_unverified_checks(self):
        summary = stage.validate_acceptance(self.beta_acceptance(), self.manifest)
        latest = stage.latest_metadata(self.manifest, summary)
        self.assertTrue(latest['prerelease'])
        self.assertEqual(latest['unverified'], summary['failed'] + summary['notRun'])
        self.assertIn('helperCrashRecovery', latest['unverified'])
        self.use_ga_version()
        ga = stage.latest_metadata(self.manifest, stage.validate_acceptance(self.acceptance(), self.manifest))
        self.assertFalse(ga['prerelease'])
        self.assertEqual(ga['unverified'], [])

    def test_public_manifest_is_only_verified_when_nothing_is_unverified(self):
        for record, verified in [(self.beta_acceptance(), False), (self.acceptance(), True)]:
            summary = stage.validate_acceptance(record, self.manifest)
            self.assertEqual(stage.acceptance_verified(summary), verified)

    def test_latest_metadata_uses_the_accepted_dmg(self):
        latest = stage.latest_metadata(self.manifest, stage.validate_acceptance(self.acceptance(), self.manifest))
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
