#if !MAS_CHANNEL
  import AppKit
  import DilatedControl
  import SwiftUI

  typealias ClaudeHooksSettings = AgentHooksSettings

  @MainActor struct AgentHooksSettings: View {
    var report: (String) -> Void
    var installation: AgentHookInstallation
    let tool: AgentHookTool

    init(
      report: @escaping (String) -> Void, installation: AgentHookInstallation? = nil,
      tool: AgentHookTool = .claude
    ) {
      self.report = report
      self.tool = installation?.tool ?? tool
      self.installation =
        installation
        ?? AgentHookInstallation(
          settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            tool == .codex ? ".codex/hooks.json" : ".claude/settings.json"),
          executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated"),
          tool: tool)
    }

    @State private var health: ClaudeHookInstallation.Health = .missing
    @State private var error: String?

    var body: some View {
      SettingsGroup(eyebrow: "CODING AGENTS") {
        SettingsRow(title: tool.title + " hooks", detail: detail) {
          Button(
            health == .installed
              ? "Verify hooks" : health == .drifted ? "Repair hooks" : "Install hooks"
          ) {
            if health == .installed { refresh() } else { change(remove: false) }
          }
          if health != .missing {
            Button("Remove hooks") { change(remove: true) }
          }
        }
        Text(
          tool == .codex
            ? "Configure hooks, then review and trust them in Codex /hooks or Settings > Hooks. Configuration and policy can disable hooks. Stop pauses automation. Existing hooks are kept and edits get a private backup. Quiet turns need hook activity at least once an hour."
            : "Keeps your Mac awake during a Claude Code turn. After an interruption, the hold can last up to 70 minutes without more hook activity. Stop pauses automation. Existing Claude settings and hooks are kept; edits get a private backup. Restart existing Claude sessions after changing hooks."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text(
          "Install Dilated in Applications before installing hooks. After moving the app, use Repair hooks to update their paths."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .onAppear(perform: refresh)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in refresh() }
    }

    private var detail: String {
      if let error { return error }
      switch health {
      case .missing: return "Missing. Install to keep awake while \(tool.title) works."
      case .installed:
        return tool == .codex
          ? "Configured. Review and trust these hooks in Codex before use."
          : "Installed. Claude turns can request awake holds."
      case .drifted:
        return tool == .codex
          ? "Drifted. Hook commands changed or are incomplete."
          : "Drifted. Hooks changed, are incomplete, or are disabled in Claude settings."
      }
    }

    private func refresh() {
      do {
        health = try installation.health()
        error = nil
      } catch { self.error = error.localizedDescription }
    }

    private func change(remove: Bool) {
      do {
        guard remove || FileManager.default.isExecutableFile(atPath: installation.executable.path)
        else {
          throw InputError("The command line tool isn't available in this copy of Dilated.")
        }
        if remove { try installation.remove() } else { try installation.install() }
        refresh()
        report(
          remove
            ? "Removed Dilated's \(tool.title) hooks."
            : tool == .codex
              ? "Configured Codex hooks. Review and trust them in Codex before use."
              : "Installed Claude Code hooks. Restart existing Claude sessions to load them.")
      } catch {
        self.error = error.localizedDescription
        report(error.localizedDescription)
      }
    }
  }
#endif
