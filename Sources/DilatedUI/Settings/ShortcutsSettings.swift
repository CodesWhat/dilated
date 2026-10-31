import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor struct ShortcutsSettings: View {
  @Bindable var model: AppModel
  @State private var editing: ShortcutAction?

  static func accessibilityValue(for shortcut: AwakeShortcut?) -> String {
    shortcut?.displayName ?? "Not assigned"
  }

  static func passesRecorderKeyThrough(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    [UInt16(kVK_Tab), UInt16(kVK_Return), UInt16(kVK_Space)].contains(keyCode)
      && modifiers.intersection([.command, .control, .option]).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "KEYBOARD") {
        ForEach(ShortcutAction.allCases) { action in
          SettingsRow(title: action.label) {
            Button(model.settings.shortcuts[action]?.displayName ?? "Record shortcut…") {
              editing = action
            }
            .accessibilityLabel("Shortcut for \(action.label)")
            .accessibilityValue(Self.accessibilityValue(for: model.settings.shortcuts[action]))
          }
        }
      }
      SettingsNote(
        text:
          "Include Control or Command. Shortcuts don't require Accessibility permission. Manual starts still work while automation is paused; Stop ends every hold and keeps automation paused until Resume."
      )
    }
    .sheet(item: $editing) { action in ShortcutRecorderView(model: model, action: action) }
  }
}

@MainActor private struct ShortcutRecorderView: View {
  @Bindable var model: AppModel
  let action: ShortcutAction
  @Environment(\.dismiss) private var dismiss
  @State private var draft: AwakeShortcut?
  @State private var recording = true
  @State private var monitor: Any?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("KEYBOARD SHORTCUT").font(DesignFont.heading(28))
      Text(action.label).font(DesignFont.sans(16, .semibold))
      Button(recording ? "Press a key combination…" : draft?.displayName ?? "Not assigned") {
        recording = true
        error = nil
      }.font(.system(size: 20, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
      Text(
        error
          ?? "Include Control or Command, then release the keys. Escape cancels. Dilated's global shortcuts are paused while this sheet is open."
      )
      .fixedSize(horizontal: false, vertical: true).foregroundStyle(
        error == nil ? DesignPalette.ink2 : DesignPalette.danger)
      HStack {
        Button("Clear") {
          draft = nil
          recording = false
          error = nil
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(recording)
      }
    }
    .padding(24).frame(width: 460)
    .font(DesignFont.sans(13)).foregroundStyle(DesignPalette.ink).background(DesignPalette.bg)
    .onAppear {
      draft = model.settings.shortcuts[action]
      model.shortcutRecording = true
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let consumed = MainActor.assumeIsolated {
          guard recording else { return false }
          if ShortcutsSettings.passesRecorderKeyThrough(
            keyCode: event.keyCode, modifiers: event.modifierFlags)
          {
            recording = false
            error = nil
            return false
          }
          if event.keyCode == 53 {
            dismiss()
            return true
          }
          if let shortcut = AwakeShortcut(event: event) {
            draft = shortcut
            recording = false
            error = nil
          } else if !event.isARepeat {
            error = "Include Control or Command with a key."
          }
          return true
        }
        return consumed ? nil : event
      }
    }
    .onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      model.shortcutRecording = false
    }
  }
  private func save() {
    model.shortcutRecording = false
    do {
      try model.assignShortcut(draft, to: action)
      dismiss()
    } catch {
      self.error = error.localizedDescription
      model.shortcutRecording = true
    }
  }
}
