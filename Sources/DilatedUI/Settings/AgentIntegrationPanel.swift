#if !MAS_CHANNEL
  import AppKit
  import DilatedControl
  import SwiftUI

  /// What differs between the agent integrations (Claude/Codex hooks, OpenCode plugin). The
  /// shared panel supplies the buttons, refresh and error handling around it.
  struct AgentIntegrationAdapter {
    /// "hooks" or "plugin", used in the button labels.
    var noun: String
    var rowTitle: String
    var executable: URL
    var overview: String
    var placement: String
    var health: () throws -> AgentHookInstallation.Health
    var install: () throws -> Void
    var remove: () throws -> Void
    var detail: (AgentHookInstallation.Health) -> String
    var installedMessage: String
    var removedMessage: String
  }

  @MainActor struct AgentIntegrationPanel: View {
    var report: (String) -> Void
    let adapter: AgentIntegrationAdapter
    @State private var health: AgentHookInstallation.Health = .missing
    @State private var issue: String?

    var body: some View {
      SettingsGroup(eyebrow: "CODING AGENTS") {
        SettingsRow(title: adapter.rowTitle, detail: issue ?? adapter.detail(health)) {
          Button(
            health == .installed
              ? "Verify \(adapter.noun)"
              : health == .drifted ? "Repair \(adapter.noun)" : "Install \(adapter.noun)"
          ) {
            if health == .installed { refresh() } else { change(remove: false) }
          }
          if health != .missing { Button("Remove \(adapter.noun)") { change(remove: true) } }
        }
        Text(adapter.overview)
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text(adapter.placement)
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .onAppear(perform: refresh)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in refresh() }
    }

    private func refresh() {
      do {
        health = try adapter.health()
        issue = nil
      } catch { issue = error.localizedDescription }
    }

    private func change(remove: Bool) {
      do {
        guard remove || FileManager.default.isExecutableFile(atPath: adapter.executable.path)
        else {
          throw InputError("The command line tool isn't available in this copy of Dilated.")
        }
        if remove { try adapter.remove() } else { try adapter.install() }
        refresh()
        report(remove ? adapter.removedMessage : adapter.installedMessage)
      } catch {
        issue = error.localizedDescription
        report(error.localizedDescription)
      }
    }
  }
#endif
