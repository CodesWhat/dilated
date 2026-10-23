// Offscreen rendering pattern adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
import AppKit
import DilatedControl
import DilatedCore
import SwiftUI
import Testing

@testable import DilatedUI

@MainActor struct SettingsRenderTests {
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
