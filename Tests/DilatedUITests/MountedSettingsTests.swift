import AppKit
import DilatedCore
import Observation
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

@MainActor struct MountedSettingsTests {
  @Test(arguments: [false, true])
  func preferencesFilePreviewAppliesOnlyAfterConfirmation(apply: Bool) throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.stopAll()
    let before = model.settings
    var imported = AppSettings()
    imported.defaultMinutes = 45
    imported.presets = [15, 45]
    var closed = false
    var mounted: SettingsProfilePreview?
    var preview = SettingsProfilePreview(
      model: model, profile: SettingsProfile(settings: imported), close: { closed = true })
    preview.didAppear = { mounted = $0 }
    let host = NSHostingView(rootView: preview.environment(\.colorScheme, .light))
    host.appearance = NSAppearance(named: .aqua)
    defer { mounted = nil }
    try render(host)
    let view = try #require(mounted)
    _ = try view.inspect().find(text: "45 minutes")
    #expect(model.settings == before && model.engine.automationPaused)
    try view.inspect().find(button: apply ? "Apply preferences" : "Cancel").tap()
    #expect(closed && model.engine.automationPaused && model.engine.holds.isEmpty)
    #expect(model.settings.defaultMinutes == (apply ? 45 : before.defaultMinutes))
    try render(host)
    if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
      let destination = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: destination.appendingPathComponent("preferences-preview-\(apply).png"))
    }
  }

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

  #if DEBUG && !MAS_CHANNEL
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

  #if DEBUG
    @Test func scheduleGridMovementSelectionClearAndPreciseRowsShareTheModel() throws {
      _ = NSApplication.shared
      var schedule = WeeklySchedule(weekdays: [2], startMinute: 570, endMinute: 1020)
      var mounted: WeeklyScheduleGrid?
      var grid = WeeklyScheduleGrid(schedule: Binding(get: { schedule }, set: { schedule = $0 }))
      grid.didAppear = { mounted = $0 }
      let host = NSHostingView(rootView: grid.padding(12).frame(width: 480))
      defer { mounted = nil }
      try render(host)
      let live = try #require(mounted)
      live.selectBlock(from: CGPoint(x: 65, y: 127), to: CGPoint(x: 350, y: 225), width: 448)
      #expect(
        schedule == WeeklySchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1020))
      let reader = try live.inspect().find(ViewType.GeometryReader.self)
      try reader.callOnMoveCommand(.right)
      try reader.callOnMoveCommand(.down)
      live.selectFocusedHour()
      #expect(schedule == WeeklySchedule(weekdays: [7], startMinute: 1020, endMinute: 1080))
      try live.inspect().find(button: "Clear schedule").tap()
      #expect(schedule.weekdays.isEmpty && !schedule.isValid)

      let rule = TriggerRule(name: "Schedule", criteria: [.schedule(schedule)])
      var criterion: (any View)?
      var saved: TriggerRule?
      var editor = TriggerRuleEditor(rule: rule, save: { saved = $0 }, remove: {})
      var mountedEditor: TriggerRuleEditor?
      editor.criterionDidAppear = { criterion = $0 }
      editor.didAppear = { mountedEditor = $0 }
      let editorHost = NSHostingView(rootView: editor)
      defer {
        criterion = nil
        mountedEditor = nil
      }
      try render(editorHost)
      let initial = try #require(criterion)
      let embedded = try initial.inspect().find(WeeklyScheduleGrid.self).actualView()
      embedded.schedule = ScheduleGridSelection.block(
        from: .init(day: 2, hour: 9), to: .init(day: 6, hour: 16))
      try render(editorHost)
      let updated = try #require(criterion)
      let start = try #require(
        Calendar.current.date(
          bySettingHour: 9, minute: 45, second: 0, of: Date()))
      try updated.inspect().findAll(ViewType.DatePicker.self)[0].select(date: start)
      try render(editorHost)
      try #require(mountedEditor).inspect().find(button: "Save").tap()
      #expect(
        saved?.criteria == [
          .schedule(
            .init(
              weekdays: [2, 3, 4, 5, 6], startMinute: 585, endMinute: 1020))
        ])
      if let output = ProcessInfo.processInfo.environment["DILATED_SETTINGS_PREVIEWS"] {
        schedule = WeeklySchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1020)
        host.rootView = grid.padding(12).frame(width: 480)
        try render(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: output).appendingPathComponent("weekly-schedule-grid.png"))
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
