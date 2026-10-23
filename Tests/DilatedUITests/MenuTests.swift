import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MenuTests {
  @Test func primaryActionAndPauseStayVisible() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() })
    defer { model.shutdown() }
    let idle = AwakeMenu.make(model: model, openSettings: {})
    #expect(idle.items.contains { $0.title == "Keep Awake" && $0.isEnabled })
    model.start(duration: 60)
    let active = AwakeMenu.make(model: model, openSettings: {})
    #expect(active.items.contains { $0.title == "Stop" && $0.isEnabled })
    #expect(active.items.contains { $0.title == "Extend" && $0.submenu != nil })
    model.stopAll()
    let paused = AwakeMenu.make(model: model, openSettings: {})
    #expect(paused.items.contains { $0.title == "Resume automation" })
    #expect(paused.items.contains { $0.title == "Keep Awake" })
    #expect(!paused.items.contains { $0.title.contains("Closed lid") })
  }
}
