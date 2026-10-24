import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MenuTests {
  @Test func menuUsesTheStatusItemAnchorAndRestoresQuickClickHandling() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    var presented: [NSMenu] = []
    let controller = MenuBarController(
      model: model, openSettings: {},
      presentMenu: { item in
        if let menu = item.menu { presented.append(menu) }
      })
    defer { controller.stop() }
    let button = try #require(controller.statusItem.button)
    let action = button.action
    let target = button.target
    controller.showMenu()
    try #require(presented.count == 1)
    #expect(controller.statusItem.menu === presented[0])
    presented[0].delegate?.menuDidClose?(presented[0])
    #expect(controller.statusItem.menu == nil)
    #expect(button.action == action && button.target === target)
    model.stopAll()
    controller.showMenu()
    try #require(presented.count == 2)
    #expect(controller.statusItem.menu === presented[1])
    presented[1].delegate?.menuDidClose?(presented[1])
    #expect(presented[0] !== presented[1])
    #expect(presented.last?.items.contains { $0.title == "Resume automation" } == true)
    #expect(controller.statusItem.menu == nil)
    #expect(button.action == action && button.target === target)
  }

  @Test func statusAndPauseUseNativeMenuRows() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.stopAll()
    model.message = "Helper needs attention."
    let menu = AwakeMenu.make(model: model, openSettings: {})
    #expect(menu.items.allSatisfy { $0.view == nil })
    #expect(menu.items.first?.isSectionHeader == true)
    #expect(menu.items.first?.title == model.statusText)
    #expect(menu.items.contains { $0.title == "Automation paused" && !$0.isEnabled })
    #expect(menu.items.contains { $0.title == model.attention && !$0.isEnabled })
  }

  @Test func nativeReasonsMenuStopsOnlyTheSelectedHold() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 60)
    model.start()
    let remaining = try #require(model.engine.holds.last)
    let menu = AwakeMenu.make(model: model, openSettings: {})
    let reasons = try #require(menu.items.first { $0.title == "Awake reasons" }?.submenu)
    #expect(reasons.items.count == 2)
    #expect(reasons.items.first?.title.hasPrefix("Stop Manual timer") == true)
    reasons.performActionForItem(at: 0)
    #expect(model.engine.holds.map(\.id) == [remaining.id])
    #expect(model.engine.automationPaused)
  }

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

  @Test func nativeStatusUpdatesWhileMenuIsOpen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    let menu = AwakeMenu.make(model: model, openSettings: {})
    let delegate: any NSMenuDelegate = controller
    delegate.menuWillOpen?(menu)
    model.stopAll()
    controller.refresh()
    #expect(menu.items.first?.title == model.statusText)
    #expect(menu.items.contains { $0.title == "Keep Awake" && $0.keyEquivalent == "d" })
    delegate.menuDidClose?(menu)
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
