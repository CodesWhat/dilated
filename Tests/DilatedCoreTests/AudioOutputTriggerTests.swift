import Foundation
import Testing

@testable import DilatedCore

struct AudioOutputTriggerTests {
  @Test func audioOutputSelectionSurvivesTheRealRuleCodec() throws {
    let data = Data(#"{"audioOutput":{"uid":"studio-output","name":"Studio speakers"}}"#.utf8)
    let criterion = try #require(try? JSONDecoder().decode(TriggerCriterion.self, from: data))
    let rule = TriggerRule(name: "Studio", criteria: [criterion])
    #expect(rule.validationMessage == nil)
    let saved = try JSONEncoder().encode(rule)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: saved) == rule)
  }

  @Test func audioOutputMatchesStableIdentityAndRejectsUnknownReadings() {
    let rule = TriggerRule(
      name: "Studio", criteria: [.audioOutput(uid: "studio-output", name: "Same name")])
    var input = TriggerInputs()
    #expect(!rule.matches(input, now: Date()))
    input.audioOutputUID = "studio-output"
    #expect(rule.matches(input, now: Date()))
    input.audioOutputUID = "other-device-with-the-same-name"
    #expect(!rule.matches(input, now: Date()))
    for criterion in [
      TriggerCriterion.audioOutput(uid: "", name: "Output"),
      .audioOutput(uid: " ", name: "Output"), .audioOutput(uid: "bad\0uid", name: "Output"),
      .audioOutput(uid: String(repeating: "a", count: 1025), name: "Output"),
      .audioOutput(uid: "output", name: ""),
    ] { #expect(!criterion.isValid) }
  }

  @Test func outputChangesHonorDwellGraceAndStopWithoutEndingOtherWork() throws {
    let now = Date()
    var rule = TriggerRule(
      name: "Studio", criteria: [.audioOutput(uid: "studio-output", name: "Speakers")])
    rule.dwellSeconds = 5
    rule.graceSeconds = 2
    var input = TriggerInputs()
    input.audioOutputUID = "studio-output"
    var engine = WakeEngine()
    let other = try engine.start(source: .manual, label: "Other work", now: now)
    var evaluator = TriggerEvaluator()
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 0)
    #expect(engine.holds.map(\.id) == [other.id])
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 5)
    #expect(engine.holds.count == 2)
    input.audioOutputUID = nil
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 6)
    #expect(engine.holds.count == 2)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 8)
    #expect(engine.holds.map(\.id) == [other.id])
    input.audioOutputUID = "studio-output"
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 9)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 14)
    #expect(engine.holds.count == 2)
    engine.stopAll(now: now)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 30)
    #expect(engine.automationPaused && engine.holds.isEmpty)
  }
}
