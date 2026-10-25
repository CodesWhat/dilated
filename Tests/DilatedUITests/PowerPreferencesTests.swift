import DilatedControl
import DilatedCore
import Foundation
import ServiceManagement
import Testing

@testable import DilatedUI

@MainActor struct PowerPreferencesTests {
  @Test func savedBatteryFloorCanBlockACRestorationAndNewStarts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var saved = WakeEngine()
    try saved.start(source: .manual, label: "Saved timer", duration: 600)
    try StateStore(directory: directory).save(saved.snapshot)
    try Data(#"{"batteryFloor":30,"batteryFloorIgnoresAC":false}"#.utf8).write(
      to: directory.appendingPathComponent("settings.json"))
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: false, batteryPercent: 15) }, assertions: PowerAssertions())
    defer { model.shutdown() }
    #expect(model.engine.holds.isEmpty)
    model.start(duration: 60)
    #expect(model.engine.holds.isEmpty)
    let response = await model.control(.init(action: .start, duration: 60))
    #expect(!response.ok && response.code == "lowBattery")
  }
  @Test func changingACExemptionAppliesImmediatelyAndPreservesPerHoldOverride() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: false, batteryPercent: 15) }, assertions: PowerAssertions())
    defer { model.shutdown() }
    model.settings.batteryFloor = 30
    model.start(duration: 60)
    #expect(model.engine.holds.count == 1)
    let policy = model.closedLidPolicy
    model.settings.batteryFloorIgnoresAC = false
    #expect(!model.engine.batteryFloorIgnoresAC)
    #expect(model.engine.holds.isEmpty)
    #expect(model.history.records.first?.endReason == .lowBattery)
    #expect(model.closedLidPolicy == policy)
    var prompted = false
    model.onBatteryOverrideNeeded = { duration in prompted = duration == 120 }
    model.start(duration: 120)
    #expect(prompted && model.engine.holds.isEmpty)
    model.start(duration: 120, batteryOverride: true)
    let approved = try #require(model.engine.holds.first)
    #expect(approved.batteryOverride == true)
    #expect(!(await model.control(.init(action: .lease, duration: 60))).ok)
    model.refreshPower()
    #expect(model.engine.holds == [approved])
    let restored = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: false, batteryPercent: 15) }, assertions: PowerAssertions())
    defer { restored.shutdown() }
    #expect(!restored.settings.batteryFloorIgnoresAC && !restored.engine.batteryFloorIgnoresAC)
    #expect(restored.engine.holds == [approved])
    restored.stopAll()
    #expect(restored.engine.holds.isEmpty && restored.engine.automationPaused)
    restored.settings.batteryFloorIgnoresAC = true
    #expect(restored.engine.automationPaused && restored.engine.holds.isEmpty)
    restored.start(duration: 60)
    #expect(restored.engine.holds.count == 1 && restored.engine.automationPaused)
  }
  @Test func missingACPreferenceKeepsLegacyBehaviorButInvalidValuesNeedRecovery() throws {
    let legacy = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"batteryFloor":30}"#.utf8))
    #expect(legacy.batteryFloorIgnoresAC)
    #expect(AppSettings().batteryFloorIgnoresAC)
    for value in [#""false""#, "null", "0"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      var saved = WakeEngine()
      try saved.start(source: .manual, label: "Saved", duration: 600)
      try StateStore(directory: directory).save(saved.snapshot)
      let data = Data("{\"batteryFloor\":30,\"batteryFloorIgnoresAC\":\(value)}".utf8)
      try data.write(to: directory.appendingPathComponent("settings.json"))
      let model = AppModel(
        endpoint: .init(stateDirectory: directory),
        power: { .init(onBattery: false, batteryPercent: 15) }, assertions: PowerAssertions())
      defer { model.shutdown() }
      #expect(model.settingsRecoveryIssue != nil)
      #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    }
  }
  @Test(arguments: [false, true])
  func updatePreparationUsesTheACGuardBeforeSavingTimers(package: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var power = PowerState(onBattery: false, batteryPercent: 50)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { power }, assertions: PowerAssertions(),
      helperInstallation: HelperInstallation(
        service: PowerHelperFixture(),
        readPower: { .init(effectiveDisabled: false, storedDisabled: false) }))
    defer { model.shutdown() }
    model.settings.batteryFloor = 30
    model.settings.batteryFloorIgnoresAC = false
    model.start(duration: 120)
    #expect(model.engine.holds.count == 1)
    power.batteryPercent = 15
    let prepared =
      if package {
        await model.prepareForPackage(
          .update, app: URL(fileURLWithPath: "/Applications/Dilated.app"))
      } else {
        await model.prepareToUpdate()
      }
    #expect(prepared)
    #expect(try StateStore(directory: directory).load().holds.isEmpty)
  }
}

@MainActor private final class PowerAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {}
  func releaseAll() {}
}

@MainActor private final class PowerHelperFixture: HelperInstalling {
  var status: SMAppService.Status { .notRegistered }
  func register() throws {}
  func unregister() async throws {}
  func openApproval() {}
}
