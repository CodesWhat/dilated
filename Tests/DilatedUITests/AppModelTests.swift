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
