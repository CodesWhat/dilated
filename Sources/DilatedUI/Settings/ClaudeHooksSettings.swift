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

    var body: some View {
      AgentIntegrationPanel(
        report: report,
        adapter: AgentIntegrationAdapter(
          noun: "hooks", rowTitle: tool.title + " hooks", executable: installation.executable,
          overview: tool == .codex
            ? "Configure hooks, then review and trust them in Codex /hooks or Settings > Hooks. Configuration and policy can disable hooks. Stop pauses automation. Existing hooks are kept and edits get a private backup. Quiet turns need hook activity at least once an hour."
            : "Keeps your Mac awake during a Claude Code turn. After an interruption, the hold can last up to 70 minutes without more hook activity. Stop pauses automation. Existing Claude settings and hooks are kept; edits get a private backup. Restart existing Claude sessions after changing hooks.",
          placement:
            "Install Dilated in Applications before installing hooks. After moving the app, use Repair hooks to update their paths.",
          health: installation.health, install: installation.install,
          remove: installation.remove, detail: detail,
          installedMessage: tool == .codex
            ? "Configured Codex hooks. Review and trust them in Codex before use."
            : "Installed Claude Code hooks. Restart existing Claude sessions to load them.",
          removedMessage: "Removed Dilated's \(tool.title) hooks."))
    }

    private func detail(_ health: AgentHookInstallation.Health) -> String {
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
  }
#endif
