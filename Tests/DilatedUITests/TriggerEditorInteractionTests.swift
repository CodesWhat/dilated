import AppKit
import DilatedCore
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

#if DEBUG
  @MainActor struct TriggerEditorInteractionTests {
    @Test(arguments: [false, true])
    func networkAndDiskThroughputEditorSavesDirectionAndThreshold(disk: Bool) throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let original: TriggerCriterion =
        disk
        ? .diskThroughput(kilobytesPerSecond: 100, atLeast: true)
        : .networkThroughput(kilobytesPerSecond: 100, atLeast: true)
      let rule = TriggerRule(name: "Transfer", criteria: [original])
      var saved: TriggerRule?
      var mounted: TriggerRuleEditor?
      var criterion: (any View)?
      defer {
        mounted = nil
        criterion = nil
      }
      var editor = TriggerRuleEditor(rule: rule, save: { saved = $0 }, remove: {})
      editor.didAppear = { mounted = $0 }
      editor.criterionDidAppear = { criterion = $0 }
      let host = NSHostingView(rootView: editor)
      try render(host)
      let liveCriterion = try #require(criterion)
      let picker = try liveCriterion.inspect().find(ViewType.Picker.self) {
        try $0.labelView().text().string() == (disk ? "Disk throughput" : "Network throughput")
      }
      try picker.select(value: false)
      try render(host)
      let updatedCriterion = try #require(criterion)
      let field = try updatedCriterion.inspect().find(ViewType.TextField.self) {
        try $0.labelView().text().string() == "KB/s"
      }
      try field.setInput("250")
      try render(host)
      try #require(mounted).inspect().find(button: "Save").tap()
      let expected: TriggerCriterion =
        disk
        ? .diskThroughput(kilobytesPerSecond: 250, atLeast: false)
        : .networkThroughput(kilobytesPerSecond: 250, atLeast: false)
      #expect(saved?.criteria == [expected])
    }

    @Test func removingTheFirstConditionSavesTheSurvivors() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let criteria: [TriggerCriterion] = [
        .power(onBattery: true), .process(name: "Xcode"), .cpu(percent: 50, atLeast: true),
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
          $0.placeholderString == "Executable name or full path"
        })
      try #require(window.makeFirstResponder(field))
      let fieldEditor = try #require(field.currentEditor() as? NSTextView)
      fieldEditor.insertText(
        "swift-build",
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
      #expect(fieldEditor.string == "swift-build")
      #expect(window.firstResponder === fieldEditor)
      try live.inspect().find(button: "Save").tap()
      let result = try #require(saved)
      #expect(result.criteria == [.process(name: "swift-build"), criteria[2]])
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
