import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct FocusRuleTests {
  private func model(_ directory: URL) -> AppModel {
    AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() }, assertions: FocusAssertions())
  }
  private func disabled(_ name: String) -> TriggerRule {
    var rule = TriggerRule(name: name, criteria: [.power(onBattery: false)])
    rule.enabled = false
    return rule
  }

  @Test func filterSwitchesOnlyItsSelectedRuleAndExitPreservesOtherHolds() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let a = disabled("A")
    let b = disabled("B")
    let other = TriggerRule(name: "Other", criteria: [.power(onBattery: false)])
    for rule in [a, b, other] { try model.saveTrigger(rule) }
    model.start(duration: 120)
    let manual = try #require(model.engine.holds.first?.id)
    model.reconcileTriggers(.init())
    let service = AutomationService()
    service.bind(model)
    #expect(try await service.focusRuleChoices().map(\.name) == ["A", "B", "Other"])
    try await service.setFocusRule(id: a.id)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.count == 3)
    #expect(model.triggerRules.first { $0.id == a.id }?.focusControlled == true)
    try await service.setFocusRule(id: b.id)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.count == 3)
    #expect(!model.engine.holds.contains { $0.label == "A" })
    #expect(model.engine.holds.contains { $0.label == "B" })
    try await service.setFocusRule(id: nil)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.count == 2 && model.engine.holds.contains { $0.id == manual })
    #expect(model.engine.holds.contains { $0.label == "Other" })
    #expect(!model.triggerRules.contains { $0.focusControlled })
    #expect(model.triggerRules.first { $0.id == b.id }?.enabled == false)
  }

  @Test func stopMasterSwitchAndPerRulePauseStillWin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    var rule = disabled("Focus")
    try model.saveTrigger(rule)
    let service = AutomationService()
    service.bind(model)
    model.stopAll()
    try await service.setFocusRule(id: rule.id)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    model.start(duration: 120)
    let manual = model.engine.holds
    try await service.setFocusRule(id: nil)
    #expect(model.engine.holds == manual && model.engine.automationPaused)
    model.resumeAutomation()
    model.settings.triggersEnabled = false
    try await service.setFocusRule(id: rule.id)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds == manual)
    rule = try #require(model.triggerRules.first)
    rule.pausedUntil = Date().addingTimeInterval(3_600)
    try model.saveTrigger(rule)
    model.settings.triggersEnabled = true
    try await service.setFocusRule(id: rule.id)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds == manual)
  }

  @Test func relaunchStagesOwnedRulesOffUntilCurrentAppFilterIsRestored() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = model(directory)
    let rule = disabled("Focus")
    try first.saveTrigger(rule)
    let service = AutomationService()
    service.bind(first)
    try await service.setFocusRule(id: rule.id)
    first.shutdown()
    let restored = model(directory)
    defer { restored.shutdown() }
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.isEmpty)
    #expect(restored.triggerRules.first?.focusControlled == true)
    #expect(restored.triggerRules.first?.enabled == false)
    service.bind(restored)
    await service.restoreFocusFilter(using: { rule.id }).value
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.count == 1)
    try await service.setFocusRule(id: nil)
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.isEmpty)
    let saved = try JSONDecoder().decode(
      [TriggerRule].self, from: Data(contentsOf: directory.appendingPathComponent("triggers.json")))
    #expect(saved.first?.enabled == false && saved.first?.focusControlled == false)
  }

  @Test func anUnknownSelectionDisablesThePreviousFilterAndReportsTheMissingRule() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let rule = disabled("Focus")
    try model.saveTrigger(rule)
    let service = AutomationService()
    service.bind(model)
    try await service.setFocusRule(id: rule.id)
    model.reconcileTriggers(.init())
    await #expect(throws: (any Error).self) { try await service.setFocusRule(id: UUID()) }
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.isEmpty)
    #expect(model.triggerRules.first?.enabled == false)
  }

  @Test func failedPersistenceCannotLeaveAnOwnedRuleRunningOrEnableAnother() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let a = disabled("A")
    let b = disabled("B")
    try model.saveTrigger(a)
    try model.saveTrigger(b)
    let service = AutomationService()
    service.bind(model)
    try await service.setFocusRule(id: a.id)
    model.reconcileTriggers(.init())
    let path = directory.appendingPathComponent("triggers.json")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await service.setFocusRule(id: b.id) }
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.isEmpty)
    #expect(model.triggerRules.allSatisfy { !$0.enabled })
  }

  @Test func lateStartupSelectionCannotOverwriteANewerFocusChange() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let a = disabled("A")
    let b = disabled("B")
    try model.saveTrigger(a)
    try model.saveTrigger(b)
    let service = AutomationService()
    service.bind(model)
    let gate = FocusLoadGate()
    let restoration = service.restoreFocusFilter(using: { await gate.load() })
    defer {
      gate.resume(nil)
      restoration.cancel()
    }
    try await gate.waitUntilStarted()
    try await service.setFocusRule(id: b.id)
    gate.resume(a.id)
    await restoration.value
    #expect(model.triggerRules.first { $0.id == b.id }?.enabled == true)
    #expect(model.triggerRules.first { $0.id == a.id }?.enabled == false)
  }

  @Test func quittingCancelsPendingRestorationAndRejectsLaterFilterWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let rule = disabled("Focus")
    try model.saveTrigger(rule)
    let service = AutomationService()
    service.bind(model)
    let gate = FocusLoadGate()
    let restoration = service.restoreFocusFilter(using: { await gate.load() })
    defer {
      gate.resume(nil)
      restoration.cancel()
    }
    try await gate.waitUntilStarted()
    service.unavailable()
    gate.resume(rule.id)
    await restoration.value
    #expect(restoration.isCancelled)
    #expect(model.triggerRules.first?.enabled == false)
    await #expect(throws: (any Error).self) { try await service.setFocusRule(id: rule.id) }
  }

  @Test func failedStartupLookupLeavesStagedRulesDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = model(directory)
    var rule = disabled("Focus")
    rule.enabled = true
    rule.focusControlled = true
    try first.saveTrigger(rule)
    first.shutdown()
    let restored = model(directory)
    defer { restored.shutdown() }
    let service = AutomationService()
    service.bind(restored)
    await service.restoreFocusFilter(using: { throw InputError("Lookup unavailable") }).value
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.isEmpty && restored.triggerRules.first?.enabled == false)
    #expect(restored.message?.contains("Focus") == true)
  }

  @Test func startupLookupCanWaitForTheApplicationToBind() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    defer { model.shutdown() }
    let rule = disabled("Focus")
    try model.saveTrigger(rule)
    let service = AutomationService()
    let restoration = service.restoreFocusFilter(using: { rule.id })
    service.bind(model)
    await restoration.value
    #expect(model.triggerRules.first?.enabled == true)
  }

  @Test func aBoundModelThatHasShutDownRejectsFocusChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = model(directory)
    let rule = disabled("Focus")
    try model.saveTrigger(rule)
    let service = AutomationService()
    service.bind(model)
    model.shutdown()
    await #expect(throws: (any Error).self) { try await service.setFocusRule(id: rule.id) }
    #expect(model.triggerRules.first?.enabled == false)
  }
}

@MainActor private final class FocusAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {}
  func releaseAll() {}
}

@MainActor private final class FocusLoadGate {
  private var continuation: CheckedContinuation<UUID?, Never>?
  func load() async -> UUID? {
    await withCheckedContinuation { continuation = $0 }
  }
  func resume(_ id: UUID?) {
    continuation?.resume(returning: id)
    continuation = nil
  }
  func waitUntilStarted() async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while continuation == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try #require(continuation != nil)
  }
}
