import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct FeedbackSettingsView: View {
  @Bindable var model: AppModel
  @State private var importing = false
  @State private var importIssue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(
        eyebrow: "NOTIFICATIONS",
        footer:
          "Banners follow your macOS notification and Focus settings. Enabling notifications asks macOS for permission; starting a hold never prompts."
      ) {
        SettingsRow(title: "Show notifications", detail: model.feedback.permission.title) {
          Toggle(
            "Show notifications",
            isOn: Binding(
              get: { model.settings.feedback.notifications },
              set: { enabled in
                if enabled {
                  Task { await model.enableFeedbackNotifications() }
                } else {
                  model.settings.feedback.notifications = false
                }
              })
          ).labelsHidden().disabled(model.feedback.requestingPermission)
        }
        HStack {
          Button("Refresh permission") { Task { await model.feedback.refreshPermission() } }
          Button("macOS notification settings") {
            NSWorkspace.shared.open(
              URL(fileURLWithPath: "/System/Applications/System Settings.app"))
          }.help("Open System Settings, then Notifications → Dilated.")
          Spacer()
          Button("Test notification") { model.feedback.testNotification() }
            .disabled(
              !model.settings.feedback.notifications || model.feedback.permission != .allowed)
        }
      }
      SettingsGroup(eyebrow: "WHEN TO NOTIFY") {
        SettingsRow(title: "Session starts") {
          Toggle("Session starts", isOn: $model.settings.feedback.sessionStarts).labelsHidden()
        }
        SettingsRow(title: "Session ends") {
          Toggle("Session ends", isOn: $model.settings.feedback.sessionEnds).labelsHidden()
        }
        SettingsRow(title: "Trigger starts") {
          Toggle("Trigger starts", isOn: $model.settings.feedback.triggerStarts).labelsHidden()
        }
        SettingsRow(title: "Trigger ends") {
          Toggle("Trigger ends", isOn: $model.settings.feedback.triggerEnds).labelsHidden()
        }
        SettingsRow(
          title: "Safety stops",
          detail:
            "Battery and Low Power Mode ends, plus closed-lid safety stops. These also report when other end alerts are off."
        ) {
          Toggle("Safety stops", isOn: $model.settings.feedback.guardStops).labelsHidden()
        }
        SettingsRow(
          title: "Include agent and script activity",
          detail: "Starts, ends and extension sounds. Lease renewals stay quiet."
        ) {
          Toggle(
            "Include agent and script activity", isOn: $model.settings.feedback.includeAutomation
          ).labelsHidden()
        }
        SettingsRow(
          title: "Remind me while awake", detail: "For any active hold. Off means no reminders."
        ) {
          Stepper(value: $model.settings.feedback.reminderMinutes, in: 0...1440, step: 1) {
            Text(
              model.settings.feedback.reminderMinutes == 0
                ? "Off" : "Every \(model.settings.feedback.reminderMinutes) min"
            )
            .monospacedDigit()
          }.frame(width: 190)
        }
      }
      SettingsGroup(
        eyebrow: "SOUNDS",
        footer:
          "Sounds are separate from notification banners and respect system volume. Custom audio is copied locally, up to 2 MB and 10 seconds. Preview plays only when you click it."
      ) {
        ForEach(FeedbackCue.allCases) { cue in soundRow(cue) }
      }
      if let issue = model.feedback.issue { SettingsNote(text: issue, tone: DesignPalette.danger) }
      if let importIssue { SettingsNote(text: importIssue, tone: DesignPalette.danger) }
    }.task { await model.feedback.refreshPermission() }
  }

  private func soundRow(_ cue: FeedbackCue) -> some View {
    SettingsRow(title: cue.rawValue) {
      HStack(spacing: 8) {
        Toggle(
          "Play on \(cue.rawValue.lowercased())",
          isOn: Binding(
            get: { model.settings.feedback[keyPath: cue.enabled] },
            set: { model.settings.feedback[keyPath: cue.enabled] = $0 })
        ).labelsHidden()
        Picker(
          "\(cue.rawValue) sound",
          selection: Binding(
            get: { model.settings.feedback[keyPath: cue.choice] },
            set: { choice in
              do {
                try model.setFeedbackSound(choice, for: cue)
                importIssue = nil
              } catch { importIssue = error.localizedDescription }
            })
        ) {
          ForEach([FeedbackSound.awake, .rest, .extended], id: \.self) { Text($0.title).tag($0) }
          let selected = model.settings.feedback[keyPath: cue.choice]
          if selected.customID != nil { Text(selected.title).tag(selected) }
        }.labelsHidden().frame(width: 145)
        Button("Import…") { chooseSound(for: cue) }.disabled(importing)
          .accessibilityLabel("Import \(cue.rawValue.lowercased()) sound")
        Button("Preview") { model.feedback.preview(model.settings.feedback[keyPath: cue.choice]) }
          .accessibilityLabel("Preview \(cue.rawValue.lowercased()) sound")
      }
    }
  }
  private func chooseSound(for cue: FeedbackCue) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = "Use sound"
    panel.begin { response in
      guard response == .OK, let file = panel.url else { return }
      importing = true
      Task {
        defer { importing = false }
        do {
          try await model.importFeedbackSound(from: file, for: cue)
          importIssue = nil
        } catch { importIssue = error.localizedDescription }
      }
    }
  }
}
