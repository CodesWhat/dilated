import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MenuTests {
  @Test func statusAttentionUsesAnAmberExclamationBesideTheTemplateEyes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    model.message = "Helper connection needs attention."
    controller.refresh()
    let button = try #require(controller.statusItem.button)
    #expect(button.image?.isTemplate == true)
    let title = button.attributedTitle
    #expect(title.string.contains("!"))
    if let range = title.string.range(of: "!") {
      let index = title.string.distance(from: title.string.startIndex, to: range.lowerBound)
      #expect(
        title.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
          == DesignPalette.NS.orange)
    }
    #expect(button.toolTip?.contains(model.message!) == true)
    model.message = nil
    model.stopAll()
    controller.refresh()
    #expect(button.attributedTitle.string.isEmpty)
  }

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
    #expect(model.attention == nil)
    #expect(model.engine.automationPaused)
    let paused = AwakeMenu.make(model: model, openSettings: {})
    #expect(paused.items.contains { $0.title == "Resume automation" })
    #expect(paused.items.contains { $0.title == "Keep Awake" })
    #expect(!paused.items.contains { $0.title.contains("Closed lid") })
  }
}
