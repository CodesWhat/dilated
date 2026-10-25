import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct TriggerModelTests {
  @Test func audioOutputRulePersistsAndOnlyEndsItsOwnReason() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let manual = try #require(model.engine.holds.first)
    let rule = TriggerRule(
      name: "Studio", criteria: [.audioOutput(uid: "test-output", name: "Speakers")])
    try model.saveTrigger(rule)
    var input = TriggerInputs()
    input.audioOutputUID = "test-output"
    model.reconcileTriggers(input)
    #expect(model.engine.holds.count == 2)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.map(\.id) == [manual.id])
    model.stopAll()
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.triggerRules == [rule])
    restored.reconcileTriggers(input)
    #expect(restored.engine.automationPaused && restored.engine.holds.isEmpty)
    restored.resumeAutomation()
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.count == 1)
    restored.removeTrigger(id: rule.id)
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func rulesPersistButConditionsAreReevaluatedAndStopRemainsDurable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    let rule = TriggerRule(
      name: "Editor", criteria: [.application(bundleID: "test.editor", frontmostOnly: false)])
    try model.saveTrigger(rule)
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    model.reconcileTriggers(input)
    #expect(model.engine.holds.map(\.label) == ["Editor"])
    model.stopAll()
    model.reconcileTriggers(input)
    #expect(model.engine.holds.isEmpty)
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.triggerRules == [rule])
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.isEmpty)
    restored.resumeAutomation()
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.isEmpty)
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.count == 1)
    restored.removeTrigger(id: rule.id)
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func resumeReevaluatesMatchingConditionsEvenWithoutAnInterveningEvent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    try model.saveTrigger(
      TriggerRule(
        name: "Editor", criteria: [.application(bundleID: "test.editor", frontmostOnly: false)]))
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    model.reconcileTriggers(input)
    model.stopAll()
    model.resumeAutomation()
    model.reconcileTriggers(input)
    #expect(model.engine.holds.count == 1)
  }

  @Test func invalidRuleDoesNotReplaceSavedConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(throws: (any Error).self) {
      try model.saveTrigger(TriggerRule(name: "Empty", criteria: []))
    }
    #expect(model.triggerRules.isEmpty)
  }
}
