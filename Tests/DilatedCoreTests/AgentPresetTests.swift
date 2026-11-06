import Foundation
import Testing

@testable import DilatedCore

struct AgentPresetTests {
  @Test func presetRequiresProcessAndCpuAndReleasesOnTheNextEvaluation() throws {
    let rule = AgentPreset.rule(process: "codex")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: now)
    var input = TriggerInputs()
    input.cpuPercent = 80
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now)
    #expect(engine.holds.isEmpty)
    input.processNames = ["codex"]
    input.cpuPercent = 0
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now)
    #expect(engine.holds.isEmpty)
    input.cpuPercent = 80
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now)
    #expect(engine.holds.first?.label.contains("decided by: CPU") == true)
    input.cpuPercent = 0
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now)
    #expect(engine.holds.isEmpty)
    input.cpuPercent = 80
    engine.stopAll(now: now)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now)
    #expect(engine.holds.isEmpty && engine.automationPaused)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule)) == rule)
  }
}
