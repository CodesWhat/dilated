#if !MAS_CHANNEL
  import AppKit
  import DilatedControl
  import SwiftUI

  @MainActor struct OpenCodeHooksSettings: View {
    var report: (String) -> Void
    var installation = OpenCodePluginInstallation(
      file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".config/opencode/plugins/dilated.js"),
      executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated"))

    var body: some View {
      AgentIntegrationPanel(
        report: report,
        adapter: AgentIntegrationAdapter(
          noun: "plugin", rowTitle: "OpenCode plugin", executable: installation.executable,
          overview:
            "Keeps awake while a session is busy and releases its hold when idle. Quiet turns need an event within one hour. Other plugins are kept; edits save a private backup. Restart OpenCode after changes.",
          placement:
            "Install Dilated in Applications before installing the plugin. After moving the app, use Repair plugin to update its path.",
          health: installation.health, install: installation.install,
          remove: installation.remove, detail: detail,
          installedMessage: "Installed OpenCode plugin. Restart OpenCode to load it.",
          removedMessage: "Removed Dilated's OpenCode plugin."))
    }

    private func detail(_ health: AgentHookInstallation.Health) -> String {
      switch health {
      case .missing: return "Missing. Install to keep awake while OpenCode works."
      case .installed: return "Installed. Restart OpenCode to load this plugin."
      case .drifted: return "Changed. Repair only replaces Dilated's plugin."
      }
    }
  }
#endif
