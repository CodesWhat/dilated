import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage_cask', ROOT / 'scripts/stage-public-release.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

HARNESS = r'''
require "json"
require "ostruct"
require "pathname"
class CaskFixture
  attr_reader :commands
  def initialize; @commands = []; end
  def cask(name); yield; end
  def version(value = nil); @version = value if value; @version; end
  def uninstall_preflight_steps(&block); @preflight = block; end
  def run(executable, **options)
    raise "wrong app base" unless options[:base] == :appdir
    raise "wrong check" unless options[:args] == ["package-check"]
    result = system_command(executable, **options)
    raise "package check failed" unless result.exit_status == 0
  end
  def appdir; Pathname("/Applications"); end
  def method_missing(*args, &block); end
  def system_command(executable, **options)
    name = File.basename(executable.to_s)
    @commands << name
    mode = ENV.fetch("DILATED_CASK_CASE")
    case name
    when "dilated"
      OpenStruct.new(exit_status: mode == "ready" ? 0 : 1, stderr: "")
    else
      raise "unexpected command"
    end
  end
  def check
    raise "missing preflight" unless @preflight
    instance_eval(&@preflight)
  end
end
fixture = CaskFixture.new
fixture.instance_eval(STDIN.read)
begin
  fixture.check
  puts JSON.generate(ok: true, commands: fixture.commands)
rescue StandardError => error
  puts JSON.generate(ok: false, message: error.message, commands: fixture.commands)
end
'''


class CaskTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'version': '1.0.0-beta.1', 'dmgSHA256': 'a' * 64}

    def run_preflight(self, mode):
        result = subprocess.run(['ruby', '-e', HARNESS], input=stage.cask_text(self.manifest),
                                text=True, capture_output=True, check=True, timeout=10,
                                env={**os.environ, 'DILATED_CASK_CASE': mode})
        return json.loads(result.stdout)

    def test_prepared_app_without_service_or_process_can_be_replaced(self):
        result = self.run_preflight('ready')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['commands'], ['dilated'])

    def test_unprepared_state_or_remaining_helper_stops_replacement(self):
        for mode in ['unprepared', 'registered', 'unknown', 'running']:
            with self.subTest(mode=mode):
                self.assertFalse(self.run_preflight(mode)['ok'])

    def test_recipe_uses_supported_declarative_preflight_and_modern_macos_dependency(self):
        recipe = stage.cask_text(self.manifest)
        self.assertIn('uninstall_preflight_steps', recipe)
        self.assertNotIn('uninstall_preflight do', recipe)
        self.assertIn('depends_on macos: :tahoe', recipe)

    def test_a_beta_cask_lists_the_checks_not_verified_on_hardware(self):
        summary = {'prerelease': True, 'passed': ['macOS26ClosedLid'], 'failed': ['helperCrashRecovery'],
                   'notRun': ['rebootRecovery']}
        recipe = stage.cask_text(self.manifest, summary)
        self.assertIn('''
  caveats <<~EOS
    Beta release. Closed-lid mode is experimental.
    Not yet verified on hardware: helperCrashRecovery, rebootRecovery.

    Before upgrading''', recipe)
        complete = {'prerelease': True, 'passed': list(stage.ACCEPTANCE_CHECKS), 'failed': [], 'notRun': []}
        self.assertEqual(stage.cask_text(self.manifest, complete), stage.cask_text(self.manifest))

    def test_a_ga_cask_is_unchanged_by_the_acceptance_summary(self):
        summary = {'prerelease': False, 'passed': list(stage.ACCEPTANCE_CHECKS), 'failed': [], 'notRun': []}
        self.assertEqual(stage.cask_text(self.manifest, summary), stage.cask_text(self.manifest))
        self.assertNotIn('Beta release', stage.cask_text(self.manifest, summary))

    def test_a_beta_cask_skips_livecheck_once_between_homepage_and_auto_updates(self):
        for acceptance in [None, {'prerelease': False, 'passed': [], 'failed': [], 'notRun': []}]:
            recipe = stage.cask_text(self.manifest, acceptance)
            self.assertEqual(recipe.count('livecheck'), 1)
            block = ('  livecheck do\n'
                     '    skip "Public beta; versions are tracked by scripts/check-cask-drift.sh."\n'
                     '  end\n\n')
            self.assertEqual(recipe.count(block), 1)
            self.assertLess(recipe.index('  homepage '), recipe.index(block))
            self.assertEqual(recipe.index(block) + len(block), recipe.index('  auto_updates '))

    def test_a_ga_cask_has_no_livecheck(self):
        ga = {'version': '1.0.0', 'dmgSHA256': 'a' * 64}
        self.assertNotIn('livecheck', stage.cask_text(ga))

    def test_release_identity_is_validated_before_creating_ruby(self):
        for manifest in [{'version': '../escape', 'dmgSHA256': 'a' * 64},
                         {'version': '1.0.0', 'dmgSHA256': 'invalid'}]:
            with self.assertRaises(ValueError):
                stage.cask_text(manifest)


if __name__ == '__main__':
    unittest.main()
