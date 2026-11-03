import AppKit
import DilatedCore
import DilatedUpdates
import Foundation
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

@MainActor private final class ChannelUpdateDriver: UpdateDriving {
  weak var delegate: (any UpdateDriverDelegate)?
  var onChange: (() -> Void)?
  var canCheckForUpdates = true
  var automaticallyChecksForUpdates = false
  func start() throws {}
  func checkForUpdates() {}
}

/// Every string a mounted view shows.
@MainActor private func shownStrings(_ view: some View) throws -> [String] {
  try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
}

@MainActor private func channelModel(_ directory: URL, withUpdateDriver: Bool = false) -> AppModel {
  let updater =
    withUpdateDriver ? AppUpdater(driver: ChannelUpdateDriver(), activity: { .idle }) : nil
  let model = AppModel(
    endpoint: .init(stateDirectory: directory), power: { .init() }, updater: updater)
  model.settings.onboardingComplete = true
  return model
}

@MainActor private func channelDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

#if DEBUG
  @MainActor private func renderChannelView(_ view: NSView, size: NSSize) throws {
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    view.layoutSubtreeIfNeeded()
  }

  /// Mounts the settings content on `page` and returns every string it shows.
  @MainActor private func settingsStrings(on page: SettingsPage, model: AppModel) throws
    -> [String]
  {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let navigation = SettingsNavigation()
    navigation.show(page)
    var mounted: SettingsContent?
    defer { mounted = nil }
    var content = SettingsContent(model: model, solid: true, navigation: navigation)
    content.didAppear = { mounted = $0 }
    let size = SettingsTheme.minimumSize
    let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    try renderChannelView(view, size: size)
    let live = try #require(mounted)
    return try shownStrings(live)
  }

  /// What the trigger editor shows for a rule holding `criterion`: the condition picker's options, every string, and the
  /// text field placeholders.
  @MainActor private func editorContents(for criterion: TriggerCriterion) throws -> (
    options: [String], shown: [String], fields: [String]
  ) {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let rule = TriggerRule(name: "Channel", criteria: [criterion])
    var mounted: (any View)?
    defer { mounted = nil }
    var editor = TriggerRuleEditor(rule: rule, save: { _ in }, remove: {})
    editor.criterionDidAppear = { mounted = $0 }
    let host = NSHostingView(rootView: editor)
    try renderChannelView(host, size: NSSize(width: 560, height: 600))
    let live = try #require(mounted)
    let picker = try live.inspect().find(ViewType.Picker.self) {
      try $0.labelView().text().string() == "Condition"
    }
    let options = try picker.findAll(ViewType.Text.self).compactMap { try? $0.string() }
    let fields = try live.inspect().findAll(ViewType.TextField.self).compactMap {
      try? $0.labelView().text().string()
    }
    return (options, try shownStrings(live), fields)
  }
#endif

#if MAS_CHANNEL
  @MainActor struct MASChannelSurfaceTests {
    @Test func channelIsMAS() {
      #expect(Distribution.current == .mas)
    }

    @Test func menuHasNoSupportOrUpdateItems() {
      let directory = channelDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = channelModel(directory, withUpdateDriver: true)
      defer { model.shutdown() }
      #expect(model.updater.isAvailable)
      let menu = AwakeMenu.make(model: model, openSettings: {})
      let titles = menu.items.map(\.title)
      #expect(titles.contains("About Dilated"))
      #expect(titles.contains("Quit Dilated"))
      #expect(!titles.contains("Support Dilated"))
      #expect(!titles.contains("Check for Updates…"))
      let submenuTitles = menu.items.flatMap { $0.submenu?.items.map(\.title) ?? [] }
      #expect(!submenuTitles.contains("Donate"))
      #expect(!submenuTitles.contains("GitHub Sponsors"))
    }

    @Test func aboutPageHasNoCreditsLineOrUpdateRow() throws {
      _ = NSApplication.shared
      let directory = channelDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = channelModel(directory, withUpdateDriver: true)
      defer { model.shutdown() }
      let strings = try shownStrings(AboutSettings(model: model))
      #expect(strings.contains("Website"))
      #expect(!strings.contains { $0.contains("free and open source") })
      #expect(!strings.contains { $0.contains("donate") || $0.contains("GitHub Sponsors") })
      #expect(!strings.contains("App updates"))
      #expect(!strings.contains("Check for Updates…"))
    }

    @Test func updaterExplainsThatUpdatesComeFromTheAppStore() {
      let updater = AppUpdater(driver: nil, activity: { .idle })
      #expect(!updater.isAvailable)
      #expect(updater.statusText == "Updates come from the Mac App Store.")
      #expect(UpdateDriverFactory.makeDriver() == nil)
    }

    @Test func helperMigrationCannotBeInjected() {
      #expect(HelperMigrationInjection.self == Never.self)
    }

    @Test func triggerMonitorIgnoresProcessTriggers() {
      let monitor = TriggerMonitor(readPower: { .init() }, changed: {})
      defer { monitor.stop() }
      let pid = ProcessInfo.processInfo.processIdentifier
      monitor.configure(rules: [
        TriggerRule(
          name: "Process",
          criteria: [
            .process(name: "/bin/sleep"),
            .processInstance(.init(pid: pid, startedAtMicroseconds: 1)),
          ])
      ])
      let input = monitor.read()
      #expect(input.processNames.isEmpty)
      #expect(input.processInstances.isEmpty)
    }

    @Test func storedProcessTriggersSurviveAndNeverMatch() throws {
      let rule = TriggerRule(name: "Keep", criteria: [.process(name: "make")])
      let data = try JSONEncoder().encode(rule)
      #expect(try JSONDecoder().decode(TriggerRule.self, from: data) == rule)
      #expect(!rule.matches(TriggerInputs(), now: Date()))
    }

    #if DEBUG
      @Test func generalSettingsHaveNoUpdateControls() throws {
        let directory = channelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = channelModel(directory, withUpdateDriver: true)
        defer { model.shutdown() }
        let strings = try settingsStrings(on: .general, model: model)
        #expect(strings.contains("Menu bar clicks"))
        for title in ["App updates", "Check for Updates…", "Check automatically", "UPDATES"] {
          #expect(!strings.contains(title))
        }
      }

      @Test func automationSettingsHaveNoCommandLineInstallRow() throws {
        let directory = channelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = channelModel(directory)
        defer { model.shutdown() }
        let strings = try settingsStrings(on: .automation, model: model)
        #expect(strings.contains("Allow automation links"))
        #expect(!strings.contains("Command line tool"))
      }

      @Test func triggerEditorOffersNoProcessKind() throws {
        let result = try editorContents(for: .power(onBattery: false))
        #expect(result.options.contains("Application"))
        #expect(!result.options.contains("Process"))
        #expect(!result.options.contains("Specific process"))
      }

      @Test func savedProcessTriggerShowsNoProcessEditor() throws {
        let named = try editorContents(for: .process(name: "make"))
        #expect(!named.fields.contains("Executable name or full path"))
        #expect(!named.shown.contains("Refresh processes"))
        #expect(named.shown.contains { $0.contains("aren't available") })
        let instance = try editorContents(
          for: .processInstance(.init(pid: 1, startedAtMicroseconds: 1)))
        #expect(!instance.shown.contains("Refresh processes"))
        #expect(instance.shown.contains { $0.contains("aren't available") })
      }
    #endif
  }
#else
  @MainActor struct DirectChannelSurfaceTests {
    @Test func channelIsDirect() {
      #expect(Distribution.current == .direct)
    }

    @Test func menuKeepsSupportAndUpdateItems() {
      let directory = channelDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = channelModel(directory, withUpdateDriver: true)
      defer { model.shutdown() }
      let titles = AwakeMenu.make(model: model, openSettings: {}).items.map(\.title)
      #expect(titles.contains("Support Dilated"))
      #expect(titles.contains("Check for Updates…"))
    }

    @Test func aboutPageKeepsCreditsLineAndUpdateRow() throws {
      _ = NSApplication.shared
      let directory = channelDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = channelModel(directory, withUpdateDriver: true)
      defer { model.shutdown() }
      let strings = try shownStrings(AboutSettings(model: model))
      #expect(strings.contains("App updates"))
      #expect(strings.contains { $0.contains("free and open source") })
    }

    @Test func updaterKeepsTheTestBuildMessage() {
      let updater = AppUpdater(driver: nil, activity: { .idle })
      #expect(updater.statusText == "Updates aren't enabled in this test build.")
    }

    #if DEBUG
      @Test func settingsKeepUpdateAndCommandLineControls() throws {
        let directory = channelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = channelModel(directory, withUpdateDriver: true)
        defer { model.shutdown() }
        let general = try settingsStrings(on: .general, model: model)
        #expect(general.contains("App updates"))
        #expect(general.contains("Check automatically"))
        let automation = try settingsStrings(on: .automation, model: model)
        #expect(automation.contains("Command line tool"))
      }

      @Test func triggerEditorOffersProcessKinds() throws {
        let result = try editorContents(for: .power(onBattery: false))
        #expect(result.options.contains("Process"))
        #expect(result.options.contains("Specific process"))
      }
    #endif
  }
#endif
