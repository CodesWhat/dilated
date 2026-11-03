import AppKit
import DilatedControl
import DilatedCore
import SwiftUI
import Testing

@testable import DilatedUI

@MainActor struct PackageSheetDismissalTests {
  @Test func packagePreparationDismissesTheShortcutRecorderSheetAndItStaysGone() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let navigation = fixture.controller.navigation
    fixture.window.contentView = NSHostingView(
      rootView: ShortcutHarness(model: fixture.model, navigation: navigation))
    fixture.window.makeKeyAndOrderFront(nil)
    pump()
    try #require(fixture.window.attachedSheet != nil)
    #expect(fixture.model.shortcutRecording)

    fixture.controller.dismissSheetForPackage(
      .init(action: .prepareUpdate), response: .init(ok: true))
    pump()
    #expect(fixture.window.attachedSheet == nil)
    #expect(!fixture.model.shortcutRecording)
  }

  @Test func packagePreparationDismissesAPresentationBoundSheetToo() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let navigation = fixture.controller.navigation
    fixture.window.contentView = NSHostingView(
      rootView: FlagHarness(navigation: navigation))
    fixture.window.makeKeyAndOrderFront(nil)
    pump()
    try #require(fixture.window.attachedSheet != nil)

    fixture.controller.dismissSheetForPackage(
      .init(action: .prepareUninstall), response: .init(ok: true))
    pump()
    #expect(fixture.window.attachedSheet == nil)
  }

  @Test func aFailedPreparationLeavesTheSheetAlone() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let navigation = fixture.controller.navigation
    fixture.window.contentView = NSHostingView(
      rootView: FlagHarness(navigation: navigation))
    fixture.window.makeKeyAndOrderFront(nil)
    pump()
    fixture.controller.dismissSheetForPackage(
      .init(action: .prepareUpdate), response: .init(ok: false))
    pump()
    #expect(fixture.window.attachedSheet != nil)
  }

  @Test func quitCallsTerminateAndForcesExitWhenTerminationNeverCompletes() async throws {
    let terminated = Counter()
    let forced = Counter()
    var quit = PackageQuit()
    quit.delay = .milliseconds(10)
    quit.grace = 0.1
    quit.terminate = { terminated.bump() }
    quit.forceExit = { forced.bump() }
    await quit.run()
    #expect(terminated.value == 1)
    #expect(forced.value == 0)
    try await Task.sleep(for: .milliseconds(600))
    #expect(forced.value == 1)
  }

  private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
}

@MainActor private struct Fixture {
  let directory: URL
  let model: AppModel
  let controller: SettingsWindow
  let window: NSWindow

  init() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    controller = SettingsWindow(model: model)
    window = try #require(controller.window)
  }
  func close() {
    controller.stop()
    controller.close()
    model.shutdown()
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func bump() { lock.withLock { count += 1 } }
}

/// Opens the sheet only for the first identity, the way a user opens it once.
private final class OpenOnce: @unchecked Sendable {
  private var open = true
  func take() -> Bool {
    defer { open = false }
    return open
  }
}

/// Mirrors how SettingsContent keys a page on the navigation epoch.
private struct ShortcutHarness: View {
  @Bindable var model: AppModel
  var navigation: SettingsNavigation
  let once = OpenOnce()
  var body: some View {
    ShortcutsSettings(model: model, editing: once.take() ? .startDefault : nil)
      .id(PageIdentity(page: .hotKeys, epoch: navigation.sheetEpoch))
  }
}

private struct FlagHarness: View {
  var navigation: SettingsNavigation
  let once = OpenOnce()
  var body: some View {
    FlagPage(presented: once.take()).id(PageIdentity(page: .triggers, epoch: navigation.sheetEpoch))
  }
}

private struct FlagPage: View {
  @State private var presented: Bool
  init(presented: Bool) { _presented = State(initialValue: presented) }
  var body: some View {
    Text("page").sheet(isPresented: $presented) { Text("sheet").frame(width: 100, height: 100) }
  }
}
