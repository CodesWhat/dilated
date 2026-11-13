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
    #expect(AboutInfo.links.count == 6)
    #expect(AboutInfo.links.contains { $0.url.absoluteString == "https://dilated.app/privacy" })
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

  #if !MAS_CHANNEL
    @Test func creditsLineLinksBothDestinations() {
      let credits = SupportLinks.credits
      #expect(
        String(credits.characters)
          == "Dilated is free and open source. If it saves you time, you can support it on GitHub Sponsors or donate directly."
      )
      let links = credits.runs.compactMap { run in
        run.link.map { (String(credits[run.range].characters), $0) }
      }
      #expect(links.map(\.0) == ["GitHub Sponsors", "donate directly"])
      #expect(
        links.map(\.1.absoluteString) == [
          "https://github.com/sponsors/CodesWhat", "https://codeswhat.com/support",
        ])
    }

    @Test func aboutPageShowsTheCreditsLine() throws {
      _ = NSApplication.shared
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      let text = try AboutSettings(model: model).inspect().find(ViewType.Text.self) {
        (try? String($0.attributedString().characters).hasPrefix("Dilated is free and open source"))
          == true
      }
      #expect(String(try text.attributedString().characters).hasSuffix("or donate directly."))
    }
  #endif

  /// Writes a PNG of the About page when `SUPPORT_RENDER_DIR` is set. A no-op otherwise.
  @Test func rendersAboutPage() throws {
    guard let directory = ProcessInfo.processInfo.environment["SUPPORT_RENDER_DIR"] else { return }
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: state) }
    let model = AppModel(endpoint: .init(stateDirectory: state), power: { .init() })
    defer { model.shutdown() }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let renderer = ImageRenderer(
      content: AboutSettings(model: model).frame(width: 560).padding(20).background(
        DesignPalette.bg))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("about.png"))
  }

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
