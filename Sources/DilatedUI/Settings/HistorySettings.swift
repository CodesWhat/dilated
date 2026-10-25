import AppKit
import DilatedCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct HistorySettings: View {
  @Bindable var model: AppModel
  @State private var source = "all"
  @State private var visibleCount = 50
  @State private var confirmingClear = false
  @State private var exportIssue: String?

  private var reasons: [SessionRecord] {
    (model.history.active.reversed() + model.history.records.reversed())
      .filter { source == "all" || $0.source.rawValue == source }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "LOCAL HISTORY") {
        SettingsRow(
          title: "Save awake history", detail: "Stored only on this Mac. No analytics or uploads."
        ) { Toggle("", isOn: $model.settings.historyEnabled).labelsHidden() }
        SettingsRow(
          title: "Keep recent history",
          detail: "Up to 2,000 completed reasons (2 MB) and 1,024 active reasons."
        ) {
          Picker("Retention", selection: $model.settings.historyRetentionDays) {
            Text("7 days").tag(7)
            Text("30 days").tag(30)
            Text("90 days").tag(90)
          }.labelsHidden().frame(width: 120)
        }
      }
      if let issue = model.historyIssue {
        Text(issue).foregroundStyle(DesignPalette.danger).fixedSize(
          horizontal: false, vertical: true)
      }
      let totals = model.history.statistics(now: model.now)
      SettingsGroup(eyebrow: "RETAINED TOTALS") {
        HStack(alignment: .top, spacing: 24) {
          total("Hold time", value: duration(totals.awakeSeconds))
          total("Completed reasons", value: String(totals.completed))
          total("Active reasons", value: String(model.history.active.count))
        }.padding(14)
        Text(
          "Time requested by Dilated, with overlapping reasons counted once. Commands running without the app have separate holds and aren't recorded."
        ).font(DesignFont.sans(12)).foregroundStyle(DesignPalette.ink2)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(
            .bottom, 12)
      }
      HStack {
        Picker("Source", selection: $source) {
          Text("All sources").tag("all")
          ForEach(
            ["manual", "cli", "lease", "runner", "url", "trigger", "shortcut", "appleScript"],
            id: \.self
          ) {
            Text(sourceName($0)).tag($0)
          }
        }.frame(maxWidth: 240)
        Spacer()
        Button("Export JSON…", action: export)
        Button("Clear history…") { confirmingClear = true }
      }
      if let exportIssue { Text(exportIssue).foregroundStyle(DesignPalette.danger) }
      SettingsGroup(eyebrow: "RECENT REASONS") {
        if reasons.isEmpty {
          Text("No recorded reasons yet.").foregroundStyle(DesignPalette.ink2).padding(14)
        } else {
          ForEach(Array(reasons.prefix(visibleCount))) { record in
            SettingsRow(
              title: record.label,
              detail:
                "\(sourceName(record.source.rawValue)) · \(record.startedAt.formatted(date: .abbreviated, time: .standard))\n\(record.endReason?.title ?? "Active")"
            ) {
              Text(
                duration(max(0, (record.endedAt ?? model.now).timeIntervalSince(record.startedAt)))
              )
              .font(DesignFont.mono(12)).monospacedDigit()
            }
          }
          if reasons.count > visibleCount {
            Button("Show more") { visibleCount += 50 }.padding(14)
          }
        }
      }
      Text(
        "Active history checkpoints every 20 seconds. After an interruption, the old segment ends at its last checkpoint; restored timers start a new segment. Changing the system clock can affect wall-clock durations."
      ).font(DesignFont.sans(12)).foregroundStyle(DesignPalette.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .confirmationDialog("Clear saved history?", isPresented: $confirmingClear) {
      Button("Clear history", role: .destructive) { model.clearHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Completed records are removed. Active reasons keep running and their history starts again now."
      )
    }
  }
  private func total(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(value).font(DesignFont.heading(28)).monospacedDigit()
      Text(title).font(DesignFont.sans(12)).foregroundStyle(DesignPalette.ink2)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func sourceName(_ source: String) -> String {
    switch source {
    case "manual": "Manual"
    case "cli": "Command line"
    case "lease": "Agent lease"
    case "runner": "Command"
    case "url": "Automation link"
    case "trigger": "Trigger"
    case "shortcut": "Shortcut"
    case "appleScript": "AppleScript"
    default: source
    }
  }
  private func duration(_ seconds: TimeInterval) -> String {
    let seconds = Int(max(0, min(seconds, Double(Int.max / 2))))
    return seconds >= 3600
      ? "\(seconds / 3600)h \(seconds % 3600 / 60)m"
      : seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
  }
  private func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "dilated-history.json"
    panel.begin { response in
      guard response == .OK, let destination = panel.url else { return }
      do {
        try model.exportHistory().write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        exportIssue = nil
      } catch { exportIssue = "Couldn't export history: \(error.localizedDescription)" }
    }
  }
}
