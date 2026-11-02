import AppKit
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

@MainActor struct AboutSettingsTests {
  @Test func versionShowsDisplayVersionAndBuild() {
    #expect(
      AboutInfo.version([
        "DilatedDisplayVersion": "1.0.0-beta.7", "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "12",
      ]) == "1.0.0-beta.7 (12)")
  }

  @Test func versionFallsBackToShortVersionThenDevelopmentBuild() {
    #expect(
      AboutInfo.version(["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "12"])
        == "1.0.0 (12)")
    #expect(AboutInfo.version(["CFBundleShortVersionString": "1.0.0"]) == "1.0.0")
    #expect(AboutInfo.version(["CFBundleVersion": "12"]) == AboutInfo.fallbackVersion)
    #expect(AboutInfo.version([:]) == AboutInfo.fallbackVersion)
    #expect(AboutInfo.version(nil) == AboutInfo.fallbackVersion)
  }

  @Test func copyrightFallsBackWhenMissingOrBlank() {
    #expect(AboutInfo.copyright(["NSHumanReadableCopyright": "Mine"]) == "Mine")
    #expect(AboutInfo.copyright([:]) == AboutInfo.fallbackCopyright)
    #expect(AboutInfo.copyright(["NSHumanReadableCopyright": "  "]) == AboutInfo.fallbackCopyright)
  }

  @Test func aboutIsTheLastPageAndLinksAreWellFormed() {
    #expect(SettingsPage.allCases.last == .about)
    #expect(AboutInfo.links.allSatisfy { $0.url.scheme == "https" })
    #expect(AboutInfo.links.count == 5)
  }

  #if DEBUG
    @Test func navigationSelectsAboutFromAnotherPageAndOnFirstAppearance() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      model.settings.onboardingComplete = true
      let size = SettingsTheme.minimumSize

      for preRequested in [false, true] {
        let navigation = SettingsNavigation()
        if preRequested { navigation.show(.about) }
        var mounted: SettingsContent?
        defer { mounted = nil }
        var content = SettingsContent(model: model, solid: true, navigation: navigation)
        content.didAppear = { mounted = $0 }
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
          defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        try render(view, size: size)
        let live = try #require(mounted)
        if !preRequested {
          #expect(try !showsAboutLinks(live))
          navigation.show(.about)
          try render(view, size: size)
        }
        #expect(navigation.requested == nil)
        #expect(try showsAboutLinks(live))
      }
    }

    private func showsAboutLinks(_ view: SettingsContent) throws -> Bool {
      (try? view.inspect().find(ViewType.Button.self) {
        try $0.accessibilityLabel().string() == "Open Website"
      }) != nil
    }
  #endif

  @Test func aboutMenuItemInvokesTheHandlerInsteadOfTheStockPanel() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    var opened = 0
    let menu = AwakeMenu.make(model: model, openSettings: {}, openAbout: { opened += 1 })
    let item = try #require(menu.items.first { $0.title == "About Dilated" })
    let target = try #require(item.target as AnyObject?)
    _ = target.perform(item.action)
    #expect(opened == 1)
  }

  private func render(_ view: NSView, size: NSSize) throws {
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    view.layoutSubtreeIfNeeded()
  }
}
