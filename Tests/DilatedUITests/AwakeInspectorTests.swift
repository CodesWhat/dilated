import AppKit
import DilatedControl
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

@MainActor struct AwakeInspectorTests {
  private func report() -> PowerAssertionReport {
    .init(
      appPID: 99,
      assertions: [
        .init(
          pid: 1, processName: "Other", type: "PreventUserIdleSystemSleep", name: "Download",
          ours: false),
        .init(
          pid: 99, processName: "Dilated", type: "PreventUserIdleSystemSleep", name: "Agent run",
          ours: true),
      ], summary: [:])
  }
  @Test func snapshotReadsOnlyWhenOpenedAndListsDilatedFirst() {
    var reads = 0
    let model = AwakeInspectorModel(read: {
      reads += 1
      return report()
    })
    #expect(reads == 0 && model.rows.isEmpty)
    model.open(reasons: ["Build"])
    #expect(reads == 1)
    #expect(model.rows.map { $0.entry.pid } == [99, 1])
    #expect(model.reasons.map(\.label) == ["Build"])
    model.open(reasons: [])
    #expect(reads == 2 && model.reasons.isEmpty)
  }
  @Test func emptySnapshotExplainsItsLimits() throws {
    let model = AwakeInspectorModel(read: { .init(appPID: 99, assertions: [], summary: [:]) })
    model.open(reasons: [])
    let view = AwakeInspectorView(reasons: [], inspector: model)
    let text = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    #expect(text.contains("No power assertions reported."))
    #expect(text.contains { $0.contains("Closed-lid") })
  }
  @Test func inspectorRendersItsSnapshot() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let inspector = AwakeInspectorModel(read: report)
    inspector.open(reasons: ["Build"])
    let host = NSHostingView(
      rootView: AwakeInspectorView(reasons: ["Build"], inspector: inspector)
        .padding(28).frame(width: 700).background(DesignPalette.bg).foregroundStyle(
          DesignPalette.ink
        )
        .font(DesignFont.sans(13)))
    host.setFrameSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 700)
    if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
      let destination = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: destination.appendingPathComponent("awake-inspector.png"))
    }
  }

  @Test func presentingAgainRefreshesButBodyUpdatesDoNotPoll() throws {
    _ = NSApplication.shared
    var reads = 0
    let inspector = AwakeInspectorModel(read: {
      reads += 1
      return report()
    })
    let navigation = SettingsNavigation()
    func content() -> some View {
      AwakeInspectorView(reasons: [], inspector: inspector).id(navigation.presentationEpoch)
        .frame(width: 700)
    }
    let host = NSHostingView(rootView: content())
    func render() throws {
      host.setFrameSize(host.fittingSize)
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    try render()
    #expect(reads == 1)
    host.rootView = content()
    try render()
    #expect(reads == 1)
    navigation.didPresent()
    host.rootView = content()
    try render()
    #expect(reads == 2)
  }

  @Test func settingsRoutePresentsTheProductionInspectorAndRefreshesOnReopen() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "inspector-window-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let controller = SettingsWindow(model: model)
    defer {
      controller.stop()
      controller.close()
    }
    let initial = controller.navigation.presentationEpoch
    for expected in 1...2 {
      controller.present(page: .inspector)
      let host = controller.hostingViewForTesting
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(controller.navigation.presentationEpoch == initial + expected)
      #expect(controller.window?.isVisible == true)
      controller.close()
    }
    #expect(model.engine.holds.isEmpty)
  }

  @Test func menuOpensTheInspector() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "inspector-menu-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { app.shutdown() }
    var opened = 0
    let menu = AwakeMenu.make(model: app, openSettings: {}, openInspector: { opened += 1 })
    let item = try #require(menu.items.first { $0.title == "Why is my Mac awake?" })
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(opened == 1 && app.engine.holds.isEmpty)
  }
}
