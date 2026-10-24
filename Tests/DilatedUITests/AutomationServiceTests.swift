import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct AutomationServiceTests {
  private func fixture(failAssertions: Bool = false) -> (URL, AppModel, AutomationService) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: AutomationAssertions(fails: failAssertions))
    let service = AutomationService()
    service.bind(model)
    return (directory, model, service)
  }

  @Test func scriptReplacementPreservesUnrelatedHoldsAndRejectsBeforeReplacing() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    model.start(duration: 120)
    let manual = try #require(model.engine.holds.first)
    let cli = await model.control(.init(action: .start, duration: 180))
    #expect(cli.ok)
    let first = try await service.startScript(.init(duration: 60))
    let second = try await service.startScript(.init(duration: 90))
    #expect(first != second)
    #expect(model.engine.holds.count == 3)
    #expect(model.engine.holds.contains(manual))
    #expect(model.engine.holds.contains { $0.id == cli.id })
    #expect(model.engine.holds.filter { $0.source == .appleScript }.map(\.id) == [second])
    let before = model.engine.holds
    await #expect(throws: (any Error).self) {
      try await service.startScript(.init(duration: -1))
    }
    #expect(model.engine.holds == before)
    #expect(model.history.active.contains { $0.source == .appleScript })
  }

  @Test func durableStopBlocksBothAdaptersWhileManualTimersRemainAvailable() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    _ = try await service.start(duration: 60)
    #expect(model.engine.holds.first?.source == .shortcut)
    try await service.stop()
    await #expect(throws: (any Error).self) { try await service.start(duration: 60) }
    await #expect(throws: (any Error).self) { try await service.startScript(.init(duration: 60)) }
    model.start(duration: 120)
    #expect(model.engine.holds.count == 1)
    #expect(model.engine.automationPaused)
    let restored = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: AutomationAssertions())
    defer { restored.shutdown() }
    #expect(restored.engine.automationPaused)
    #expect(restored.engine.holds == model.engine.holds)
  }

  @Test func scriptLidTargetUsesItsOwnHoldThenRequiresOneUnambiguousHold() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    #expect(throws: (any Error).self) { try model.scriptClosedLidTarget() }
    model.start(duration: 120)
    let manual = try #require(model.engine.holds.first)
    #expect(try model.scriptClosedLidTarget() == manual.id)
    model.start(duration: 240)
    #expect(throws: (any Error).self) { try model.scriptClosedLidTarget() }
    let own = try await service.startScript(.init(duration: 60))
    #expect(try model.scriptClosedLidTarget() == own)
  }

  @Test func statusDoesNotRenewTimersAndUnknownHelperStateIsNotReportedOff() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    let id = try await service.start(duration: 60)
    let original = model.engine.holds
    let status = try await service.status()
    #expect(status.contains(id.uuidString))
    #expect(status.contains("Helper state: unknown"))
    #expect(model.engine.holds == original)
  }

  @Test func triggerMasterPreservesRuleChoicesAndNeverResumesAutomation() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
    model.reconcileTriggers(.init())
    model.start(duration: 120)
    #expect(model.engine.holds.count == 2)
    try await service.setTriggersEnabled(false)
    #expect(model.engine.holds.count == 1)
    #expect(model.engine.holds.first?.source == .manual)
    #expect(model.triggerRules.first?.enabled == true)
    try await service.stop()
    try await service.setTriggersEnabled(true)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
    #expect(model.settings.triggersEnabled)
  }

  @Test func commandsReportPersistenceAndAssertionFailures() async throws {
    for failAssertions in [false, true] {
      let (directory, model, service) = fixture(failAssertions: failAssertions)
      defer {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
      }
      if !failAssertions {
        let state = StateStore(directory: directory).file
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      }
      await #expect(throws: (any Error).self) { try await service.start(duration: 60) }
    }
  }

  @Test func unreadyUnavailableAndCancelledServicesFailWithoutCreatingAModel() async throws {
    let service = AutomationService(readinessTimeout: .milliseconds(20))
    await #expect(throws: (any Error).self) { try await service.status() }
    service.unavailable()
    await #expect(throws: (any Error).self) { try await service.start(duration: 60) }
    let task = Task { try await AutomationService().status() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func scriptQueriesAggregateHoldsAndDisplayChangesPreserveDeadlines() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    #expect(try await service.script(.remaining) == .integer(-3))
    _ = try await service.startScript(.init(duration: 120))
    let timed = model.engine.holds
    #expect(try await service.script(.isActive) == .boolean(true))
    #expect(try await service.script(.remaining) == .integer(120))
    #expect(try await service.script(.displayAllowed) == .boolean(true))
    #expect(try await service.script(.preventDisplaySleep) == .none)
    #expect(model.engine.holds.map(\.id) == timed.map(\.id))
    #expect(model.engine.holds.map(\.expiry) == timed.map(\.expiry))
    #expect(model.engine.desiredState.displayAwake)
    try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
    model.reconcileTriggers(.init())
    #expect(try await service.script(.isTrigger) == .boolean(true))
    #expect(try await service.script(.remaining) == .integer(-1))
    model.start()
    #expect(try await service.script(.remaining) == .integer(0))
    await #expect(throws: (any Error).self) { try await service.script(.closedLidEnabled) }
    try await service.stop()
    _ = try await service.script(.preventDisplaySleep)
    #expect(!model.settings.allowDisplaySleep)
    #expect(try await service.script(.displayAllowed) == .boolean(false))
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
  }

  @Test func failedSettingsWritePreservesTriggerMasterAndExistingWork() async throws {
    let (directory, model, service) = fixture()
    defer {
      model.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
    try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
    model.reconcileTriggers(.init())
    let original = model.engine.holds
    let settings = directory.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await service.setTriggersEnabled(false) }
    #expect(model.settings.triggersEnabled)
    #expect(model.engine.holds == original)
  }
}

@MainActor private final class AutomationAssertions: AssertionControlling {
  var fails = false
  init(fails: Bool = false) { self.fails = fails }
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {
    if fails { throw InputError("Fixture assertion failure") }
  }
  func releaseAll() {}
}
