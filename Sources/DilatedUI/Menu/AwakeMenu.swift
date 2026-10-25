// NSMenu composition follows CodesWhat/Mouthtype's DailyMenu, Scott Benson, MIT.
import AppKit
import DilatedCore

@MainActor private final class MenuCommand: NSObject {
  let body: () -> Void
  init(_ body: @escaping () -> Void) { self.body = body }
  @objc func runCommand() { body() }
}

@MainActor enum AwakeMenu {
  static func action(
    _ title: String, key: String = "", state: Bool = false, body: @escaping () -> Void
  ) -> NSMenuItem {
    let command = MenuCommand(body)
    let item = NSMenuItem(
      title: title, action: #selector(MenuCommand.runCommand), keyEquivalent: key)
    item.target = command
    item.representedObject = command
    item.state = state ? .on : .off
    return item
  }

  static func make(model: AppModel, openSettings: @escaping () -> Void) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(.sectionHeader(title: model.statusText))
    if model.closedLid.active { menu.addItem(information("Closed-lid armed")) }
    if model.engine.automationPaused { menu.addItem(information("Automation paused")) }
    if let attention = model.attention { menu.addItem(information(attention)) }
    menu.addItem(.separator())
    menu.addItem(
      action(model.engine.holds.isEmpty ? "Keep Awake" : "Stop", key: "d") { model.toggle() })
    if model.engine.automationPaused {
      menu.addItem(action("Resume automation") { model.resumeAutomation() })
    }
    let durations = NSMenu()
    durations.autoenablesItems = false
    for minutes in model.settings.presets {
      let title =
        minutes >= 60 && minutes % 60 == 0
        ? "\(minutes / 60) hour\(minutes == 60 ? "" : "s")" : "\(minutes) minutes"
      durations.addItem(action(title) { model.start(duration: Double(minutes * 60)) })
    }
    durations.addItem(.separator())
    durations.addItem(action("For a duration…") { prompt(model: model, until: false) })
    durations.addItem(action("Until a time…") { prompt(model: model, until: true) })
    durations.addItem(action("Indefinitely") { model.start() })
    durations.addItem(.separator())
    durations.addItem(
      action("While a file downloads…") { chooseDownload(model: model, folder: false) })
    durations.addItem(
      action("While a folder downloads…") { chooseDownload(model: model, folder: true) })
    let durationItem = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
    durationItem.submenu = durations
    menu.addItem(durationItem)
    if !model.engine.holds.isEmpty {
      let reasons = NSMenu()
      reasons.autoenablesItems = false
      for hold in model.engine.holds.prefix(6) {
        let remaining =
          hold.expiry.map { AppModel.remaining(until: $0, now: model.now) + " left" }
          ?? "Indefinite"
        reasons.addItem(action("Stop \(hold.label) (\(remaining))") { model.stop(id: hold.id) })
      }
      if model.engine.holds.count > 6 {
        reasons.addItem(
          action("\(model.engine.holds.count - 6) more in Settings…", body: openSettings))
      }
      let item = NSMenuItem(title: "Awake reasons", action: nil, keyEquivalent: "")
      item.submenu = reasons
      menu.addItem(item)
    }
    let timed = model.engine.holds.filter { $0.expiry != nil }
    if !timed.isEmpty {
      let extend = NSMenu()
      extend.autoenablesItems = false
      for hold in timed {
        for seconds in [900.0, 3600.0] {
          let label = timed.count == 1 ? "" : "\(hold.label): "
          extend.addItem(
            action("\(label)+\(seconds == 900 ? "15 minutes" : "1 hour")") {
              model.extend(id: hold.id, seconds: seconds)
            })
        }
      }
      let item = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
      item.submenu = extend
      menu.addItem(item)
    }
    if let hold = model.engine.holds.last(where: { $0.source == .manual })
      ?? model.engine.holds.last
    {
      menu.addItem(
        action("Allow display sleep for \(hold.label)", state: !hold.displayAwake) {
          model.setDisplayAwake(id: hold.id, enabled: !hold.displayAwake)
        })
      let lid = action("Work with lid closed for \(hold.label)", state: hold.closedLid == true) {
        Task {
          do { try await model.setClosedLid(id: hold.id, enabled: hold.closedLid != true) } catch {
            model.message = error.localizedDescription
            model.onChange?()
          }
        }
      }
      lid.isEnabled = !model.closedLid.busy && !model.helperInstallation.busy
      menu.addItem(lid)
    }
    if model.closedLid.active || model.closedLid.state?.readback.effectiveDisabled == true {
      menu.addItem(action("Sleep now") { Task { await model.sleepNow() } })
    }
    menu.addItem(.separator())
    menu.addItem(action("Settings…", key: ",", body: openSettings))
    menu.addItem(
      action("About Dilated") {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
      })
    menu.addItem(action("Quit Dilated", key: "q") { NSApp.terminate(nil) })
    return menu
  }

  static func refreshStatus(in menu: NSMenu, model: AppModel) {
    menu.items.first?.title = model.statusText
    menu.items.first { $0.keyEquivalent == "d" }?.title =
      model.engine.holds.isEmpty ? "Keep Awake" : "Stop"
  }

  private static func information(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private static func chooseDownload(model: AppModel, folder: Bool) {
    let panel = NSOpenPanel()
    panel.title = folder ? "Choose a download folder" : "Choose a downloading file"
    panel.message =
      folder
      ? "Watch .crdownload, .part, .download and .partial items in this folder."
      : "Watch this file until it stops changing."
    panel.canChooseFiles = !folder
    panel.canChooseDirectories = folder
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let alert = NSAlert()
    alert.messageText = "Keep awake while downloading"
    alert.informativeText =
      "End this hold after the download stops changing for this many seconds (5–3600). "
      + "A stalled download also ends the hold. Other awake holds keep running."
    let input = NSTextField(string: "30")
    input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    input.setAccessibilityLabel("Seconds without download activity")
    alert.accessoryView = input
    alert.addButton(withTitle: "Keep Awake")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = input
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      guard let seconds = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
        (5...3600).contains(seconds)
      else { throw DownloadInputError() }
      try model.startDownload(
        .init(url: url, mode: folder ? .folder : .file), quietSeconds: Double(seconds))
    } catch { model.message = error.localizedDescription }
    model.onChange?()
  }

  private static func prompt(model: AppModel, until: Bool) {
    let alert = NSAlert()
    alert.messageText = until ? "Keep awake until" : "Keep awake for"
    alert.informativeText =
      until
      ? "Enter a local time in 24-hour format. A past time means tomorrow."
      : "Use seconds, minutes or hours, such as 30s, 90m or 2h."
    let input = NSTextField(string: until ? "17:00" : "90m")
    input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = input
    alert.addButton(withTitle: "Keep Awake")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()
    alert.window.initialFirstResponder = input
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let duration =
        until ? try TimeInput.until(value).timeIntervalSinceNow : try TimeInput.duration(value)
      model.start(duration: duration)
    } catch { model.message = error.localizedDescription }
  }
}

private struct DownloadInputError: LocalizedError {
  var errorDescription: String? { "Choose an inactivity interval from 5 seconds to 1 hour." }
}
