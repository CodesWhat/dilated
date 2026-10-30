import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct AppModelTests {
  @Test func installationBlocksNewStartsButStillAcceptsStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 120)
    model.updater.updateWillRelaunch()
    model.start()
    #expect(model.engine.holds.count == 1)
    let blocked = await model.control(.init(action: .start, duration: 60))
    #expect(!blocked.ok)
    let stopped = await model.control(.init(action: .stopAll))
    #expect(stopped.ok)
    #expect(model.engine.holds.isEmpty)
    model.updater.updateFinished(error: nil)
    model.start(duration: 60)
    #expect(model.engine.holds.count == 1)
  }

  @Test func applyPresetsSortsAndDedupesValidText() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.applyPresets(text: "60, 15, 15, 30"))
    #expect(model.settings.presets == [15, 30, 60])
    #expect(AppModel.presetsText(model.settings.presets) == "15, 30, 60")
  }

  @Test func applyPresetsResetsDefaultOnlyWhenItLeavesThePresets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.applyPresets(text: "15, 30, 60"))
    model.settings.defaultMinutes = 30
    #expect(model.applyPresets(text: "30, 45"))
    #expect(model.settings.defaultMinutes == 30)
    #expect(model.applyPresets(text: "45, 90"))
    #expect(model.settings.defaultMinutes == 0)
  }

  @Test func applyPresetsRejectsInvalidTextWithoutChangingAnything() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.applyPresets(text: "15, 30, 60"))
    let eleven = (1...11).map(String.init).joined(separator: ", ")
    for text in ["", "15, abc", "0", "10081", eleven] {
      model.message = nil
      #expect(!model.applyPresets(text: text), "\(text)")
      #expect(model.settings.presets == [15, 30, 60], "\(text)")
      #expect(model.message == "Use up to 10 durations between 1 and 10080 minutes.", "\(text)")
    }
  }

  @Test func plannedUpdateRestoresOnlyTimersWithTheirOriginalDeadlines() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { PowerState() })
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 120)
    model.start()
    let timer = try #require(model.engine.holds.first { $0.expiry != nil })
    #expect(await model.prepareToUpdate())
    model.shutdown()
    let restored = AppModel(endpoint: endpoint, power: { PowerState() })
    defer { restored.shutdown() }
    #expect(restored.engine.automationPaused)
    #expect(restored.engine.holds.count == 1)
    #expect(restored.engine.holds.first == timer)
  }

  @Test func stopPersistsAcrossModelsAndQuitDiscardsTimers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { PowerState() })
    defer { model.shutdown() }
    model.start(duration: 60)
    #expect(model.engine.holds.count == 1)
    model.stopAll()
    model.start(duration: 120)
    #expect(model.engine.automationPaused)
    let restored = AppModel(endpoint: endpoint, power: { PowerState() })
    defer { restored.shutdown() }
    #expect(restored.engine.automationPaused)
    #expect(restored.engine.holds.count == 1)
    let paused = await restored.control(ControlRequest(action: .start))
    #expect(!paused.ok)
    restored.resumeAutomation()
    let resumed = await restored.control(ControlRequest(action: .lease, duration: 30))
    #expect(resumed.ok)
    restored.shutdown()
    let afterQuit = AppModel(endpoint: endpoint, power: { PowerState() })
    defer { afterQuit.shutdown() }
    #expect(afterQuit.engine.holds.isEmpty)
  }
  @Test func controlReportsNativeAssertionFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() },
      assertions: UnavailableAssertions())
    defer { model.shutdown() }
    let response = await model.control(ControlRequest(action: .start, duration: 60))
    #expect(!response.ok)
    #expect(response.code == "systemFailure")
    #expect(model.message?.contains("Power management unavailable") == true)
  }
  @Test func partialSettingsKeepNewDefaults() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"onboardingComplete":true,"glyph":"can"}"#.utf8).write(
      to: directory.appendingPathComponent("settings.json"))
    let model = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() })
    defer { model.shutdown() }
    #expect(model.settings.onboardingComplete)
    #expect(model.settings.glyph == .can)
    #expect(model.settings.allowDisplaySleep)
    #expect(model.message == nil)
  }
  @Test func freshDefaultsAndCorruptStateAreVisible() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() })
    #expect(model.settings.defaultMinutes == 0)
    #expect(model.settings.allowDisplaySleep)
    model.shutdown()
    try Data("broken".utf8).write(to: StateStore(directory: directory).file)
    let corrupt = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() })
    defer { corrupt.shutdown() }
    #expect(corrupt.engine.automationPaused)
    #expect(corrupt.message != nil)
  }
  @Test func unreadableSettingsDoNotRestoreTimersWithoutTheirSafetyPreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var saved = WakeEngine()
    try saved.start(source: .manual, label: "Saved timer", duration: 600)
    try StateStore(directory: directory).save(saved.snapshot)
    let file = directory.appendingPathComponent("settings.json")
    let original = Data(#"{"batteryFloor":30,"glyph":"#.utf8)
    try original.write(to: file)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: true, batteryPercent: 15) })
    defer { model.shutdown() }
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
    #expect(model.attention != nil)
    #expect(try Data(contentsOf: file) == original)
  }
  @Test func unreadableSettingsBlockStartsAndChangesButStillAcceptStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.json")
    let original = Data("broken".utf8)
    try original.write(to: file)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: RecoveryAssertions())
    defer { model.shutdown() }
    model.begin()
    model.start(duration: 60, batteryOverride: true)
    model.automaticStart(label: "At launch")
    model.resumeAutomation()
    model.settings.batteryFloor = 10
    #expect(model.settings.batteryFloor == 0)
    for origin in [ControlOrigin.commandLine, .url, .shortcut] {
      for action in [ControlAction.start, .lease, .runner, .renew, .toggle, .helperSetup] {
        let response = await model.control(.init(action: action, duration: 60), origin: origin)
        #expect(!response.ok)
        #expect(response.code == "settingsRecovery")
      }
    }
    for action in [ControlAction.status, .stopAll] {
      #expect(await model.control(.init(action: action)).ok)
    }
    let status = await model.control(.init(action: .status))
    #expect(status.message == model.attention)
    await #expect(throws: (any Error).self) {
      try await model.startScript(.init(duration: 60))
    }
    model.message = "Couldn't reset closed-lid."
    #expect(model.attention == model.message)
    model.stopAll()
    #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    #expect(model.attention?.contains("settings") == true)
    #expect(try Data(contentsOf: file) == original)
    let persisted = try StateStore(directory: directory).load()
    #expect(persisted.holds.isEmpty && persisted.automationPaused)
  }
  @Test func settingsResetPreservesOriginalAndLeavesAutomationPaused() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.json")
    let original = Data("broken".utf8)
    try original.write(to: file)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: RecoveryAssertions())
    defer { model.shutdown() }
    let backup = try model.resetUnreadableSettings()
    #expect(try Data(contentsOf: backup) == original)
    let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(
      try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: file)) == AppSettings())
    #expect(model.settingsRecoveryIssue == nil && model.attention == nil)
    #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    let persisted = try StateStore(directory: directory).load()
    #expect(persisted.holds.isEmpty && persisted.automationPaused)
    model.start(duration: 60)
    #expect(model.engine.holds.count == 1 && model.engine.automationPaused)
  }
  @Test func settingsResetFailurePreservesOriginalAndRecoveryGate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.json")
    let original = Data("broken".utf8)
    try original.write(to: file)
    try Data("occupied".utf8).write(to: directory.appendingPathComponent("recovery"))
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: RecoveryAssertions())
    defer { model.shutdown() }
    #expect(throws: (any Error).self) { try model.resetUnreadableSettings() }
    #expect(model.settingsRecoveryIssue != nil)
    model.start(duration: 60)
    model.resumeAutomation()
    #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    #expect(try Data(contentsOf: file) == original)
  }
  @Test func settingsResetCannotPublishDefaultsBeforePersistingThePause() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("settings.json")
    let original = Data("broken".utf8)
    try original.write(to: file)
    try FileManager.default.createDirectory(
      at: StateStore(directory: directory).file, withIntermediateDirectories: true)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: RecoveryAssertions())
    defer { model.shutdown() }
    #expect(throws: (any Error).self) { try model.resetUnreadableSettings() }
    #expect(model.settingsRecoveryIssue != nil)
    #expect(try Data(contentsOf: file) == original)
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("recovery"), includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
  }
}

@MainActor private final class RecoveryAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {}
  func releaseAll() {}
}

@MainActor private final class UnavailableAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {
    throw NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Power management unavailable"]
    )
  }
  func releaseAll() {}
}
