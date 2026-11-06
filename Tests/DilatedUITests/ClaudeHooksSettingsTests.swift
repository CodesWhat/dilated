#if !MAS_CHANNEL
  import AppKit
  import DilatedControl
  import Foundation
  import SwiftUI
  import Testing
  import ViewInspector
  @testable import DilatedUI

  @MainActor struct ClaudeHooksSettingsTests {
    @Test func controlsRenderWithoutTouchingUserSettings() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hooks-render-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: directory) }
      let installation = ClaudeHookInstallation(
        settingsURL: directory.appendingPathComponent("settings.json"),
        executable: URL(fileURLWithPath: "/usr/bin/true"))
      let host = NSHostingView(
        rootView: ClaudeHooksSettings(report: { _ in }, installation: installation)
          .padding(28).frame(width: 620).background(DesignPalette.bg).foregroundStyle(
            DesignPalette.ink
          ).font(DesignFont.sans(13)))
      host.setFrameSize(host.fittingSize)
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(bitmap.pixelsWide >= 620)
      #expect(!FileManager.default.fileExists(atPath: installation.settingsURL.path))
      if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: destination.appendingPathComponent("claude-hooks.png"))
      }
    }

    @Test func installButtonWritesOnlyTheSelectedClaudeSettings() throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hooks-ui-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: directory) }
      let installation = ClaudeHookInstallation(
        settingsURL: directory.appendingPathComponent("settings.json"),
        executable: URL(fileURLWithPath: "/usr/bin/true"))
      var message = ""
      let view = ClaudeHooksSettings(report: { message = $0 }, installation: installation)
      try view.inspect().find(button: "Install hooks").tap()
      #expect(try installation.health() == .installed)
      #expect(message.contains("Restart existing Claude sessions"))
    }
  }
#endif
