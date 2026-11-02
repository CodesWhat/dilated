import AppKit
import DilatedCore
import Observation
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

@MainActor struct MountedSettingsTests {
  @Test func insertingARowPreservesTheExistingRowsStateAndFocus() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let fixture = GroupFixtureState()
    let view = NSHostingView(rootView: GroupFixture(fixture: fixture).frame(width: 400))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    try render(view)
    let originalHeight = view.fittingSize.height
    let field = try #require(descendants(of: view).compactMap { $0 as? NSTextField }.first)
    let original = field.stringValue
    try #require(!original.isEmpty)
    try #require(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor())
    #expect(window.firstResponder === editor)

    fixture.inserted = true
    try render(view)
    try #require(view.fittingSize.height > originalHeight)
    let survivor = try #require(descendants(of: view).compactMap { $0 as? NSTextField }.first)
    #expect(survivor.stringValue == original)
    #expect(survivor === field)
    #expect(window.firstResponder === editor)
  }

  #if DEBUG
    @Test func specificProcessPickerLoadsWithoutPressingRefresh() throws {
      _ = NSApplication.shared
      FontRegistry.registerBundledFonts()
      let pid = ProcessInfo.processInfo.processIdentifier
      let process = try #require(ProcessCatalog.read().first { $0.id == pid })
      let rule = TriggerRule(name: "This process", criteria: [.processInstance(process.identity)])
      var mounted: (any View)?
      var editor = TriggerRuleEditor(rule: rule, save: { _ in }, remove: {})
      editor.criterionDidAppear = { mounted = $0 }
      let view = NSHostingView(rootView: editor)
      try render(view)
      defer { mounted = nil }
      let live = try #require(mounted)
      let picker = try live.inspect().find(ViewType.Picker.self) {
        try $0.labelView().text().string() == "Process"
      }
      let title = "\(process.name) (\(pid))"
      let option = try picker.find(ViewType.Text.self) { try $0.string() == title }
      #expect(try option.tag() as? ProcessIdentity == process.identity)
      #expect(throws: (any Error).self) {
        try picker.find(ViewType.Text.self) { try $0.string() == "PID \(pid) (ended)" }
      }
    }
  #endif

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

@MainActor @Observable private final class GroupFixtureState {
  var inserted = false
}

@MainActor private struct GroupFixture: View {
  @Bindable var fixture: GroupFixtureState

  var body: some View {
    SettingsGroup(eyebrow: "TEST") {
      if fixture.inserted { Text("Inserted above") }
      StatefulGroupRow()
    }
  }
}

@MainActor private struct StatefulGroupRow: View {
  @State private var value = UUID().uuidString

  var body: some View { TextField("Retained value", text: $value) }
}
