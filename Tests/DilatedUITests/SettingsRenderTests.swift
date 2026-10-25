// Offscreen rendering pattern adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
import AppKit
import DilatedControl
import DilatedCore
import SwiftUI
import Testing

@testable import DilatedUI

@MainActor struct SettingsRenderTests {
  @Test func closedLidSettingsRenderWithoutInstallingOrStartingTheHelper() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 3600)
    let view = NSHostingView(
      rootView: ClosedLidSettings(model: model).padding(28).frame(width: 660)
        .background(DesignPalette.bg).foregroundStyle(DesignPalette.ink)
        .font(DesignFont.sans(13)))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 660)
    #expect(model.closedLid.state == nil)
    #expect(!model.engine.desiredState.closedLid)
    if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
      let destination = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: destination.appendingPathComponent("closed-lid-settings.png"))
    }
  }
  @Test func triggerEditorRendersRealConditionsWithoutStartingAHold() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let bluetooth = try #require(BluetoothDeviceIdentity(address: "01:23:45:67:89:ab"))
    let rule = TriggerRule(
      name: "Editor on AC",
      criteria: [
        .application(bundleID: "com.apple.TextEdit", frontmostOnly: true), .power(onBattery: false),
        .schedule(.init(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1020)),
        .volume(path: "/"), .cpu(percent: 20, atLeast: true), .idle(seconds: 300, atLeast: false),
        .bluetooth(device: bluetooth, name: "Saved studio device"),
      ])
    let view = NSHostingView(rootView: TriggerRuleEditor(rule: rule, save: { _ in }, remove: {}))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 560 && bitmap.pixelsHigh >= 600)
  }

  @Test func notificationAndSoundControlsRenderWithoutPromptingOrPlaying() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let view = NSHostingView(
      rootView: FeedbackSettingsView(model: model).padding(28).frame(width: 700))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 700)
    #expect(!model.settings.feedback.notifications && !model.settings.feedback.startSound)
    #expect(model.engine.holds.isEmpty && !model.feedback.requestingPermission)
  }

  @Test func driveAliveSettingsRenderWithWritesDisabled() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let view = NSHostingView(
      rootView: DriveAliveSettingsView(model: model).padding(28).frame(width: 700))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 700)
    #expect(!model.settings.driveAlive.enabled && model.engine.holds.isEmpty)
  }

  @Test func historyRendersRealActiveAndCompletedReasons() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    model.stopAll()
    model.start(duration: 120)
    let view = NSHostingView(rootView: HistorySettings(model: model).padding(28).frame(width: 700))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= 700)
    #expect(model.history.records.count == 1 && model.history.active.count == 1)
  }

  @Test func settingsRenderInLightAndDarkWithoutShowingAWindow() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: SocketEndpoint(stateDirectory: directory), power: { PowerState() })
    defer { model.shutdown() }
    model.begin()
    model.settings.onboardingComplete = true
    model.start(duration: 3600)
    for dark in [false, true] {
      let size = SettingsTheme.windowSize
      let view = NSHostingView(
        rootView: SettingsContent(model: model, solid: true)
          .frame(width: size.width, height: size.height)
          .environment(\.colorScheme, dark ? .dark : .light))
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
        defer: false)
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = view
      view.setFrameSize(size)
      view.layoutSubtreeIfNeeded()
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      #expect(!window.isVisible)
      #expect(bitmap.pixelsWide >= 900 && bitmap.pixelsHigh >= 620)
      if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: destination.appendingPathComponent(dark ? "settings-dark.png" : "settings-light.png"))
      }
    }
  }
}
