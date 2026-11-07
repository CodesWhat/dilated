import AppKit
import DilatedControl
import DilatedCore
import DilatedUpdates
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MenuTests {
  @Test func customDurationPhrasesStartAndInvalidInputPreservesTheHold() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    AwakeMenu.applyDurationInput(model: model, text: "2h30", until: false)
    let hold = try #require(model.engine.holds.first)
    #expect(abs(try #require(hold.expiry).timeIntervalSince(hold.createdAt) - 9000) < 0.01)
    let before = model.engine.holds
    AwakeMenu.applyDurationInput(model: model, text: "until 5", until: false)
    #expect(model.engine.holds == before)
    #expect(model.message != nil)
  }

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

  private func flushMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  /// Opens the real controller menu, captures only weak handles to the item's target, then closes.
  private func openAndClose(
    _ controller: MenuBarController, title: String, presented: inout [NSMenu]
  ) -> (target: WeakBox, action: Selector)? {
    controller.showMenu()
    guard let menu = presented.last, let item = menu.items.first(where: { $0.title == title })
    else { return nil }
    let box = WeakBox(item.target as AnyObject?)
    let action = item.action
    let delegate = menu.delegate
    presented.removeAll()
    delegate?.menuDidClose?(menu)
    return (box, action!)
  }

  private func makeController(
    _ model: AppModel, presented: UnsafeMutablePointer<[NSMenu]>
  ) -> MenuBarController {
    _ = NSApplication.shared
    return MenuBarController(
      model: model, openSettings: {},
      presentMenu: { item in if let menu = item.menu { presented.pointee.append(menu) } })
  }

  @Test func menuActionsSurviveMenuDidCloseBeforeDispatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let presented = UnsafeMutablePointer<[NSMenu]>.allocate(capacity: 1)
    presented.initialize(to: [])
    defer { presented.deallocate() }
    let controller = makeController(model, presented: presented)
    defer { controller.stop() }

    model.stopAll()
    #expect(model.engine.automationPaused)
    var resume = autoreleasepool {
      openAndClose(controller, title: "Resume automation", presented: &presented.pointee)
    }
    try #require(resume != nil)
    #expect(resume?.target.value != nil)
    _ = (resume!.target.value as? NSObject)?.perform(resume!.action)
    #expect(!model.engine.automationPaused)
    await flushMainQueue()
    resume = nil

    let keep = autoreleasepool {
      openAndClose(controller, title: "Keep Awake", presented: &presented.pointee)
    }
    try #require(keep != nil)
    _ = (keep!.target.value as? NSObject)?.perform(keep!.action)
    #expect(!model.engine.holds.isEmpty)
    await flushMainQueue()

    let stop = autoreleasepool {
      openAndClose(controller, title: "Stop", presented: &presented.pointee)
    }
    try #require(stop != nil)
    _ = (stop!.target.value as? NSObject)?.perform(stop!.action)
    #expect(model.engine.holds.isEmpty)
    await flushMainQueue()
  }

  @Test func reopeningTheMenuKeepsItsCommandsAcrossThePreviousDeferredRelease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let presented = UnsafeMutablePointer<[NSMenu]>.allocate(capacity: 1)
    presented.initialize(to: [])
    defer { presented.deallocate() }
    let controller = makeController(model, presented: presented)
    defer { controller.stop() }

    model.stopAll()
    let (box, action) = try autoreleasepool {
      controller.showMenu()
      let first = try #require(presented.pointee.last)
      first.delegate?.menuDidClose?(first)
      // Reopen before the first close's deferred release runs.
      controller.showMenu()
      let second = try #require(presented.pointee.last)
      let box = WeakBox(
        second.items.first { $0.title == "Resume automation" }?.target as AnyObject?)
      let action = try #require(second.items.first { $0.title == "Resume automation" }?.action)
      presented.pointee.removeAll()
      return (box, action)
    }
    await flushMainQueue()
    autoreleasepool {
      if let second = controller.statusItem.menu { second.delegate?.menuDidClose?(second) }
    }
    #expect(box.value != nil)
    _ = (box.value as? NSObject)?.perform(action)
    #expect(!model.engine.automationPaused)
    await flushMainQueue()
    #expect(box.value == nil)
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

  #if !MAS_CHANNEL
    @Test func supportSubmenuSitsBetweenAboutAndQuit() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      let menu = AwakeMenu.make(model: model, openSettings: {})
      let titles = menu.items.map(\.title)
      let about = try #require(titles.firstIndex(of: "About Dilated"))
      #expect(titles[about + 1] == "Support Dilated")
      #expect(titles[about + 2] == "Quit Dilated")
      let support = menu.items[about + 1]
      #expect(support.image == nil)
      let submenu = try #require(support.submenu)
      #expect(submenu.items.map(\.title) == ["GitHub Sponsors", "Donate"])
      #expect(
        SupportLinks.all.map(\.url.absoluteString) == [
          "https://github.com/sponsors/CodesWhat", "https://codeswhat.com/support",
        ])
      #expect(submenu.items.allSatisfy { $0.image == nil && $0.action != nil && $0.target != nil })
      if let directory = ProcessInfo.processInfo.environment["SUPPORT_RENDER_DIR"] {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true)
        let dump = (titles + ["Support Dilated >"] + submenu.items.map { "  " + $0.title })
          .joined(separator: "\n")
        try dump.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("menu.txt"), atomically: true,
          encoding: .utf8)
      }
    }

    @Test func checkForUpdatesSitsBetweenSettingsAndAboutOnlyWhenAvailable() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
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

      model.onChange = { AwakeMenu.refreshStatus(in: menu, model: model) }
      driver.canCheckForUpdates = false
      driver.onChange?()
      #expect(!model.updater.canCheckForUpdates)
      let disabled = AwakeMenu.make(model: model, openSettings: {})
      #expect(disabled.items.first { $0.title == "Check for Updates…" }?.isEnabled == false)
      #expect(!item.isEnabled)

      driver.canCheckForUpdates = true
      driver.onChange?()
      #expect(item.isEnabled)
      let target = try #require(item.target as AnyObject?)
      _ = target.perform(item.action)
      #expect(driver.checks == 1)
    }
  #endif

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

private final class WeakBox {
  weak var value: AnyObject?
  init(_ value: AnyObject?) { self.value = value }
}
