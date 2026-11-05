#if !MAS_CHANNEL
  import AppKit
  import DilatedControl
  import SwiftUI

  @MainActor struct ClaudeHooksSettings: View {
    var report: (String) -> Void
    var installation = ClaudeHookInstallation(
      settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".claude/settings.json"),
      executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated"))
    @State private var health: ClaudeHookInstallation.Health = .missing
    @State private var error: String?

    var body: some View {
      SettingsGroup(eyebrow: "CODING AGENTS") {
        SettingsRow(title: "Claude Code hooks", detail: detail) {
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
          "Keeps your Mac awake during a Claude Code turn. After an interruption, the hold can last up to 70 minutes without more hook activity. Stop pauses automation. Existing Claude settings and hooks are kept; edits get a private backup. Restart existing Claude sessions after changing hooks."
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
      case .missing: return "Missing. Install to keep awake while Claude works."
      case .installed: return "Installed. Claude turns can request awake holds."
      case .drifted:
        return "Drifted. Hooks changed, are incomplete, or are disabled in Claude settings."
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
            ? "Removed Dilated's Claude Code hooks."
            : "Installed Claude Code hooks. Restart existing Claude sessions to load them.")
      } catch {
        self.error = error.localizedDescription
        report(error.localizedDescription)
      }
    }
  }
#endif
