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
  def uninstall_preflight(&block); @preflight = block; end
  def appdir; Pathname("/Applications"); end
  def method_missing(*args, &block); end
  def system_command(executable, **options)
    name = File.basename(executable.to_s)
    @commands << name
    mode = ENV.fetch("DILATED_CASK_CASE")
    case name
    when "dilated"
      raise "preparation missing" if mode == "unprepared"
      OpenStruct.new(exit_status: 0, stderr: "")
    when "launchctl"
      code = mode == "registered" ? 0 : mode == "unknown" ? 5 : 113
      OpenStruct.new(exit_status: code, stderr: 'Could not find service "com.codeswhat.dilated.helper"')
    when "pgrep"
      OpenStruct.new(exit_status: mode == "running" ? 0 : 1, stderr: "")
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
        self.assertEqual(result['commands'], ['dilated', 'launchctl', 'pgrep'])

    def test_unprepared_state_or_remaining_helper_stops_replacement(self):
        for mode in ['unprepared', 'registered', 'unknown', 'running']:
            with self.subTest(mode=mode):
                self.assertFalse(self.run_preflight(mode)['ok'])

    def test_release_identity_is_validated_before_creating_ruby(self):
        for manifest in [{'version': '../escape', 'dmgSHA256': 'a' * 64},
                         {'version': '1.0.0', 'dmgSHA256': 'invalid'}]:
            with self.assertRaises(ValueError):
                stage.cask_text(manifest)


if __name__ == '__main__':
    unittest.main()
