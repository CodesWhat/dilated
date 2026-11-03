import AppKit
import DilatedSetupCore
import SwiftUI

@MainActor @Observable final class SetupModel {
  var status: ClosedLidSetupStatus?
  var message = ""
  var isBusy = false

  private let setup: ClosedLidSetup

  init(setup: ClosedLidSetup = .live()) { self.setup = setup }

  func refresh() async { status = await setup.status() }

  func install() async { await perform("Installed.") { await setup.install() } }

  func remove() async { await perform("Removed.") { await setup.remove() } }

  private func perform(
    _ success: String, _ action: () async -> ClosedLidSetupOutcome
  ) async {
    isBusy = true
    message = ""
    switch await action() {
    case .completed: message = success
    case .cancelled: message = "Cancelled."
    case .failed(let reason): message = reason
    }
    await refresh()
    isBusy = false
  }
}

struct SetupView: View {
  @State private var model = SetupModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Dilated Closed-Lid Setup").font(.title2.bold())
      Text("Lets the Mac App Store version of Dilated keep your Mac awake with the lid closed.")
        .foregroundStyle(.secondary)
      if let status = model.status {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
          row("Sleep permission", Self.ruleText(status.rule))
          row("Helper script", Self.scriptText(status.script))
          row("Safety agent", status.agent == .loaded ? "Loaded" : "Not loaded")
        }
      } else {
        ProgressView().controlSize(.small)
      }
      if !model.message.isEmpty { Text(model.message).font(.callout) }
      HStack {
        Button("Install") { Task { await model.install() } }
          .keyboardShortcut(.defaultAction)
        Button("Remove") { Task { await model.remove() } }
      }
      .disabled(model.isBusy)
    }
    .padding(24)
    .frame(width: 440)
    .task { await model.refresh() }
  }

  private func row(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value)
    }
  }

  static func ruleText(_ status: ClosedLidSetupRuleStatus) -> String {
    switch status {
    case .ready: "Ready"
    case .allowedByOtherRule: "Allowed by another app's rule"
    case .missing: "Missing"
    case .needsRepair: "Needs repair"
    case .blocked: "Blocked"
    case .notAdmin: "This account isn't an administrator"
    }
  }

  static func scriptText(_ status: ClosedLidSetupScriptStatus) -> String {
    switch status {
    case .present: "Installed"
    case .outdated: "Out of date"
    case .missing: "Missing"
    }
  }
}

struct SetupApp: App {
  var body: some Scene {
    Window("Dilated Closed-Lid Setup", id: "setup") {
      SetupView()
    }
    .windowResizability(.contentSize)
  }
}
