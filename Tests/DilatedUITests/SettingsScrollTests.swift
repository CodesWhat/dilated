import AppKit
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

#if DEBUG
  @MainActor struct SettingsScrollTests {
    @Test func changingPagesStartsTheDetailPaneAtTheTop() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      let controller = SettingsWindow(model: model)
      defer {
        controller.stop()
        controller.close()
      }
      let window = try #require(controller.window)
      let host = try #require(controller.hostingViewForTesting as? NSHostingView<SettingsContent>)
      var mounted: SettingsContent?
      defer { mounted = nil }
      var content = host.rootView
      content.didAppear = { mounted = $0 }
      host.rootView = content
      try render(host)
      let live = try #require(mounted)
      for page in ["General", "Menu Bar", "General"] {
        try live.inspect().find(ViewType.Button.self) {
          (try? $0.accessibilityLabel().string()) == page
        }.tap()
        try render(host)
        let scroll = try #require(
          descendants(of: host).compactMap { $0 as? NSScrollView }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
          })
        let document = try #require(scroll.documentView)
        let clip = scroll.contentView
        try #require(clip.bounds.height > 500)
        try #require(document.bounds.height > clip.bounds.height + 1)
        var topBounds = clip.bounds
        topBounds.origin.y =
          document.isFlipped
          ? document.frame.minY - clip.bounds.height : document.frame.maxY + clip.bounds.height
        let top = clip.constrainBoundsRect(topBounds).minY
        let bottom =
          document.isFlipped
          ? document.bounds.maxY - clip.bounds.height : document.bounds.minY
        #expect(abs(clip.bounds.minY - top) < 0.5, "\(page) opens at the top")
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
        scroll.reflectScrolledClipView(clip)
        try render(host)
        try #require(abs(clip.bounds.minY - top) > 1)
        #expect(!window.isVisible)
      }
    }

    private func descendants(of root: NSView) -> [NSView] {
      [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func render(_ view: NSView) throws {
      view.layoutSubtreeIfNeeded()
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
  }
#endif
