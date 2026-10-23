// NSMenu composition follows CodesWhat/Mouthtype's DailyMenu, Scott Benson, MIT.
import AppKit
import DilatedCore
import SwiftUI

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
    let card = NSMenuItem()
    let hosting = NSHostingView(rootView: AwakeCard(model: model) { menu.cancelTracking() })
    hosting.frame = NSRect(x: 0, y: 0, width: 340, height: hosting.fittingSize.height)
    card.view = hosting
    menu.addItem(card)
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
    let durationItem = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
    durationItem.submenu = durations
    menu.addItem(durationItem)
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

@MainActor private struct AwakeCard: View {
  @Bindable var model: AppModel
  var close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("DILATED").font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
      Text(model.statusText).font(.system(size: 16, weight: .semibold)).fixedSize(
        horizontal: false, vertical: true)
      if model.closedLid.active {
        Text("Closed-lid armed").font(.system(size: 11, weight: .medium))
      }
      if let attention = model.attention {
        Text(attention).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      ForEach(Array(model.engine.holds.prefix(6))) { hold in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(hold.label).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(
              hold.expiry.map { AppModel.remaining(until: $0, now: model.now) + " left" }
                ?? "Indefinite"
            )
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Stop") {
            close()
            model.stop(id: hold.id)
          }.buttonStyle(.borderless).font(.system(size: 11))
            .accessibilityLabel("Stop \(hold.label)")
        }
      }
      if model.engine.holds.count > 6 {
        Text("\(model.engine.holds.count - 6) more reasons in Settings").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14).frame(width: 340, alignment: .leading)
  }
}
