import DilatedCore
import Foundation
import SwiftUI

@MainActor @Observable final class AwakeInspectorModel {
  struct Row: Identifiable {
    let id = UUID()
    let entry: PowerAssertionEntry
  }
  struct Reason: Identifiable {
    let id = UUID()
    let label: String
  }
  private(set) var rows: [Row] = []
  private(set) var reasons: [Reason] = []
  private let read: () -> PowerAssertionReport

  init(
    read: @escaping () -> PowerAssertionReport = {
      AssertionInspector.report(appPID: ProcessInfo.processInfo.processIdentifier)
    }
  ) { self.read = read }

  func open(reasons: [String]) {
    self.reasons = reasons.map { Reason(label: $0) }
    let entries = read().assertions
    rows = (entries.filter(\.ours) + entries.filter { !$0.ours }).map { Row(entry: $0) }
  }
}

@MainActor struct AwakeInspectorView: View {
  let reasons: [String]
  @State private var inspector: AwakeInspectorModel

  init(reasons: [String], inspector: AwakeInspectorModel = AwakeInspectorModel()) {
    self.reasons = reasons
    _inspector = State(initialValue: inspector)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if !inspector.reasons.isEmpty {
        SettingsGroup(eyebrow: "DILATED AWAKE REASONS") {
          ForEach(inspector.reasons) { reason in
            SettingsNote(text: reason.label)
          }
        }
      }
      SettingsGroup(eyebrow: "MACOS POWER ASSERTIONS") {
        if inspector.rows.isEmpty {
          SettingsNote(text: "No power assertions reported.")
        } else {
          ForEach(inspector.rows) { row in
            SettingsRow(
              title: row.entry.processName ?? "Unknown process",
              detail:
                "PID \(row.entry.pid) · \(row.entry.type)\n\(row.entry.name ?? "Unnamed request")"
            ) {
              if row.entry.ours { Text("Dilated").foregroundStyle(.secondary) }
            }
          }
        }
      }
      Text(
        "Apps can ask macOS to stay awake. This list shows those requests when you open this page. Closed-lid settings and other macOS behavior can also affect sleep. Change another app's requests in that app."
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { inspector.open(reasons: reasons) }
  }
}
