import AppKit
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

#if DEBUG
  @MainActor struct TriggerEditorInteractionTests {
    @Test func removingTheFirstConditionSavesTheSurvivors() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let criteria: [TriggerCriterion] = [
        .power(onBattery: true), .network(address: "192.0.2.1"), .cpu(percent: 50, atLeast: true),
      ]
      let rule = TriggerRule(name: "Three conditions", criteria: criteria)
      var saved: TriggerRule?
      var mounted: TriggerRuleEditor?
      defer { mounted = nil }
      var editor = TriggerRuleEditor(rule: rule, save: { saved = $0 }, remove: {})
      editor.didAppear = { mounted = $0 }
      let host = NSHostingView(rootView: editor)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      try render(host)
      let field = try #require(
        descendants(of: host).compactMap { $0 as? NSTextField }.first {
          $0.placeholderString == "IPv4, IPv6 or CIDR range"
        })
      try #require(window.makeFirstResponder(field))
      let fieldEditor = try #require(field.currentEditor() as? NSTextView)
      fieldEditor.insertText(
        "192.0.2.2",
        replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
      try render(host)
      let live = try #require(mounted)
      let remove = try live.inspect().findAll(ViewType.Button.self).filter {
        try $0.labelView().text().string() == "Remove condition"
      }
      try #require(remove.count == 3)
      try remove[0].tap()
      try render(host)
      #expect(descendants(of: host).contains { $0 === field })
      #expect(fieldEditor.string == "192.0.2.2")
      #expect(window.firstResponder === fieldEditor)
      try live.inspect().find(button: "Save").tap()
      let result = try #require(saved)
      #expect(result.criteria == [.network(address: "192.0.2.2"), criteria[2]])
      #expect(!window.isVisible)
    }

    private func descendants(of root: NSView) -> [NSView] {
      [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func render(_ view: NSView) throws {
      view.setFrameSize(view.fittingSize)
      view.layoutSubtreeIfNeeded()
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
    }
  }
#endif
