import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MenuTests {
  @Test func countdownFormatPersistsWithoutChangingOtherPreferences() throws {
    let settings = try JSONDecoder().decode(
      AppSettings.self,
      from: Data(#"{"countdown":true,"countdownFormat":"clock","swapClicks":true}"#.utf8))
    let saved = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    #expect(saved["countdownFormat"] as? String == "clock")
    #expect(settings.countdown && settings.swapClicks)
  }

  @Test func clockCountdownRoundsUpAndClampsExpiredTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (seconds, expected) in [
      (-1.0, "0:00"), (0, "0:00"), (0.1, "0:01"), (59, "0:59"),
      (59.1, "1:00"), (90, "1:30"), (3599, "59:59"),
      (3599.1, "1:00:00"), (5400, "1:30:00"), (90061, "25:01:01"),
    ] {
      #expect(
        CountdownFormat.clock.remaining(until: now.addingTimeInterval(seconds), now: now)
          == expected)
    }
    #expect(
      CountdownFormat.compact.remaining(until: now.addingTimeInterval(5400), now: now)
        == "1h 30m")
  }

  @Test func missingAndUnknownCountdownFormatsPreserveExistingSettings() throws {
    for json in [
      #"{"countdown":true,"swapClicks":true}"#,
      #"{"countdown":true,"countdownFormat":"future","swapClicks":true}"#,
    ] {
      let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
      #expect(settings.countdownFormat == .compact)
      #expect(settings.countdown && settings.swapClicks)
    }
  }

  @Test func clockCountdownKeepsIndefiniteAndHiddenStates() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"countdown":true,"countdownFormat":"clock"}"#.utf8).write(
      to: directory.appendingPathComponent("settings.json"))
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 5400)
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    let button = try #require(controller.statusItem.button)
    #expect(button.attributedTitle.string.contains(":"))
    model.start()
    controller.refresh()
    #expect(button.attributedTitle.string == " ∞")
    model.settings.countdown = false
    controller.refresh()
    #expect(button.attributedTitle.string.isEmpty)
    model.settings.countdown = true
    model.stopAll()
    controller.refresh()
    #expect(button.attributedTitle.string.isEmpty)
  }

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

  @Test func checkForUpdatesSitsBetweenSettingsAndAboutOnlyWhenAvailable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let plain = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      updater: AppUpdater(driver: nil, activity: { .idle }))
    defer { plain.shutdown() }
    #expect(
      !AwakeMenu.make(model: plain, openSettings: {}).items.contains {
        $0.title == "Check for Updates…"
      })

    let driver = MenuUpdateDriver()
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      updater: AppUpdater(driver: driver, activity: { .idle }))
    defer { model.shutdown() }
    model.updater.start()
    let menu = AwakeMenu.make(model: model, openSettings: {})
    let titles = menu.items.map(\.title)
    let settings = try #require(titles.firstIndex(of: "Settings…"))
    #expect(titles[settings + 1] == "Check for Updates…")
    #expect(titles[settings + 2] == "About Dilated")
    let item = menu.items[settings + 1]
    #expect(item.isEnabled == model.updater.canCheckForUpdates)

    driver.canCheckForUpdates = false
    driver.onChange?()
    #expect(!model.updater.canCheckForUpdates)
    let disabled = AwakeMenu.make(model: model, openSettings: {})
    #expect(disabled.items.first { $0.title == "Check for Updates…" }?.isEnabled == false)
    AwakeMenu.refreshStatus(in: menu, model: model)
    #expect(!item.isEnabled)

    driver.canCheckForUpdates = true
    driver.onChange?()
    AwakeMenu.refreshStatus(in: menu, model: model)
    #expect(item.isEnabled)
    let target = try #require(item.target as AnyObject?)
    _ = target.perform(item.action)
    #expect(driver.checks == 1)
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

@MainActor private final class MenuUpdateDriver: UpdateDriving {
  weak var delegate: (any UpdateDriverDelegate)?
  var onChange: (() -> Void)?
  var canCheckForUpdates = true
  var automaticallyChecksForUpdates = false
  var checks = 0
  func start() throws {}
  func checkForUpdates() { checks += 1 }
}
