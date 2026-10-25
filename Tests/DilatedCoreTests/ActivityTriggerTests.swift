import Foundation
import Testing

@testable import DilatedCore

struct ActivityTriggerTests {
  @Test func activityAndVolumeConditionsRequireKnownInputs() {
    let now = Date()
    var input = TriggerInputs()
    let cpu = TriggerRule(name: "Busy", criteria: [.cpu(percent: 20, atLeast: true)])
    let idle = TriggerRule(name: "Recent input", criteria: [.idle(seconds: 300, atLeast: false)])
    let volume = TriggerRule(name: "Archive", criteria: [.volume(path: "/Volumes/Archive")])
    #expect(!cpu.matches(input, now: now))
    #expect(!idle.matches(input, now: now))
    #expect(!volume.matches(input, now: now))
    input.cpuPercent = 20
    input.idleSeconds = 300
    input.mountedVolumes = ["/Volumes/Archive"]
    #expect(cpu.matches(input, now: now) && idle.matches(input, now: now))
    #expect(volume.matches(input, now: now))
    input.cpuPercent = 19.9
    input.idleSeconds = 301
    input.mountedVolumes = []
    #expect(!cpu.matches(input, now: now) && !idle.matches(input, now: now))
    #expect(!volume.matches(input, now: now))
    input.cpuPercent = .nan
    input.idleSeconds = .infinity
    #expect(!cpu.matches(input, now: now) && !idle.matches(input, now: now))
    #expect(!TriggerCriterion.cpu(percent: -1, atLeast: false).isValid)
    #expect(!TriggerCriterion.idle(seconds: -.infinity, atLeast: true).isValid)
    #expect(!TriggerCriterion.volume(path: "relative/path").isValid)
  }

  @Test func cpuSamplesUseDeltasAndHandleCounterWrapWithoutAssumingZeroLoad() {
    var sampler = CPUUsageSampler()
    #expect(sampler.sample([100, 100, 800, 0]) == nil)
    #expect(sampler.sample([120, 110, 870, 0]) == 30)
    #expect(sampler.sample([120, 110, 870, 0]) == nil)
    #expect(sampler.sample(nil) == nil)
    #expect(sampler.sample([1, 1, 1, 1]) == nil)
    var wrapping = CPUUsageSampler()
    #expect(wrapping.sample([UInt32.max - 9, 0, UInt32.max - 79, 0]) == nil)
    #expect(wrapping.sample([10, 0, 0, 0]) == 20)
  }

  @Test func activityRulesRespectDwellGraceAndTheDurableStop() throws {
    let start = Date()
    var rule = TriggerRule(
      name: "Busy archive",
      criteria: [.cpu(percent: 10, atLeast: true), .volume(path: "/Volumes/Archive")])
    rule.dwellSeconds = 30
    rule.graceSeconds = 10
    var input = TriggerInputs()
    input.cpuPercent = 30
    input.mountedVolumes = ["/Volumes/Archive"]
    var engine = WakeEngine()
    var evaluator = TriggerEvaluator()
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start, uptime: 0)
    #expect(engine.holds.isEmpty)
    evaluator.reconcile(
      rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(30), uptime: 30)
    #expect(engine.holds.count == 1)
    input.mountedVolumes = []
    evaluator.reconcile(
      rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(31), uptime: 31)
    #expect(engine.holds.count == 1)
    evaluator.reconcile(
      rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(41), uptime: 41)
    #expect(engine.holds.isEmpty)
    engine.stopAll()
    input.mountedVolumes = ["/Volumes/Archive"]
    evaluator.reconcile(
      rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(100), uptime: 100
    )
    #expect(engine.holds.isEmpty && engine.automationPaused)
  }
}
