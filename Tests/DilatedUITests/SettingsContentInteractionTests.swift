import AppKit
import DilatedControl
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

#if DEBUG
  @MainActor struct SettingsContentInteractionTests {
    @Test(arguments: ["30, ", ""])
    func changingGlassPreservesTheSelectedPageAndUnsavedPresets(draft: String) throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      let originalPresets = model.settings.presets
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
      let page = try live.inspect().find(ViewType.Button.self) {
        try $0.accessibilityLabel().string() == "Keep Awake"
      }
      try page.tap()
      try render(host)
      let field = try #require(
        descendants(of: host).compactMap { $0 as? NSTextField }.first {
          $0.placeholderString == "15, 30, 60"
        })
      try #require(window.makeFirstResponder(field))
      let editor = try #require(field.currentEditor() as? NSTextView)
      editor.insertText(
        draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      try render(host)
      try #require(field.stringValue == draft)
      for solid in [true, false, true] {
        controller.applyContent(solid: solid)
        try render(host)
        let retained = try #require(
          descendants(of: host).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "15, 30, 60"
          })
        #expect(retained.stringValue == draft)
        #expect(model.settings.presets == originalPresets)
        #expect(controller.hostingViewForTesting === host)
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
