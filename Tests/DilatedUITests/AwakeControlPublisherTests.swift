import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct AwakeControlPublisherTests {
  @Test func publishesOnlyChangedStateAndRetainsStopPause() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AwakeControlStateStore(directory: directory)
    var reloads = 0
    let publisher = AwakeControlPublisher(store: store, appPID: 42) { reloads += 1 }
    var engine = WakeEngine()
    publisher.publish(engine.snapshot)
    #expect(reloads == 1)
    publisher.publish(engine.snapshot)
    #expect(reloads == 1)
    _ = try engine.start(source: .manual, label: "Manual", duration: 60)
    publisher.publish(engine.snapshot)
    #expect(reloads == 2)
    #expect(store.read()?.isAwake(at: Date(), hostIsRunning: true) == true)
    engine.stopAll()
    publisher.publish(engine.snapshot)
    #expect(reloads == 3)
    #expect(store.read()?.automationPaused == true)
    #expect(store.read()?.isAwake(at: Date(), hostIsRunning: true) == false)
  }

  @Test func failedWriteCanRetryWithoutReloadingStaleState() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    var reloads = 0
    let store = AwakeControlStateStore(directory: file)
    let publisher = AwakeControlPublisher(store: store, appPID: 42) { reloads += 1 }
    publisher.publish(.init())
    #expect(reloads == 0)
    try FileManager.default.removeItem(at: file)
    publisher.publish(.init())
    #expect(reloads == 1)
    #expect(store.read() != nil)
  }

  @Test func quittingClearsIndefiniteStateWithoutPausingAutomation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AwakeControlStateStore(directory: directory)
    let publisher = AwakeControlPublisher(store: store, appPID: 42, reload: {})
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Indefinite")
    publisher.publish(engine.snapshot)
    engine.quit()
    publisher.publish(engine.snapshot)
    #expect(store.read()?.hasIndefiniteHold == false)
    #expect(store.read()?.automationPaused == false)
  }
}
