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
    @State private var health: AgentHookInstallation.Health = .missing
    @State private var issue: String?

    var body: some View {
      SettingsGroup(eyebrow: "CODING AGENTS") {
        SettingsRow(title: "OpenCode plugin", detail: detail) {
          Button(
            health == .installed
              ? "Verify plugin" : health == .drifted ? "Repair plugin" : "Install plugin"
          ) {
            if health == .installed { refresh() } else { change(remove: false) }
          }
          if health != .missing { Button("Remove plugin") { change(remove: true) } }
        }
        Text(
          "Keeps awake while a session is busy and releases its hold when idle. Quiet turns need an event within one hour. Other plugins are kept; edits save a private backup. Restart OpenCode after changes."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .onAppear(perform: refresh)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in refresh() }
    }

    private var detail: String {
      if let issue { return issue }
      switch health {
      case .missing: return "Missing. Install to keep awake while OpenCode works."
      case .installed: return "Installed. Restart OpenCode to load this plugin."
      case .drifted: return "Changed. Repair only replaces Dilated's plugin."
      }
    }
    private func refresh() {
      do {
        health = try installation.health()
        issue = nil
      } catch { issue = error.localizedDescription }
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
            ? "Removed Dilated's OpenCode plugin."
            : "Installed OpenCode plugin. Restart OpenCode to load it.")
      } catch {
        issue = error.localizedDescription
        report(error.localizedDescription)
      }
    }
  }
#endif
