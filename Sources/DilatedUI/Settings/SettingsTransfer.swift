import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct SettingsTransferSection: View {
  @Bindable var model: AppModel
  @State private var pending: PendingImport?
  private struct PendingImport: Identifiable {
    let id = UUID()
    let profile: SettingsProfile
  }
  var body: some View {
    SettingsGroup(eyebrow: "PREFERENCES FILE") {
      SettingsRow(
        title: "Move preferences to another Mac",
        detail:
          "Transfer timer and appearance preferences with built-in icons. Custom PNGs stay local."
      ) {
        Button("Export…", action: export)
        Button("Import…", action: read)
          .disabled(model.settingsRecoveryIssue != nil)
      }
    }
    .sheet(item: $pending) { pending in
      SettingsProfilePreview(model: model, profile: pending.profile, close: { self.pending = nil })
    }
  }
  private func export() {
    let profile = SettingsProfile(settings: model.settings)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Dilated Preferences.json"
    panel.begin { result in
      guard result == .OK, let url = panel.url else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        try profile.write(to: url)
        model.message = "Preferences exported."
      } catch { model.message = "Couldn't export preferences: \(error.localizedDescription)" }
    }
  }
  private func read() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.begin { result in
      guard result == .OK, let url = panel.url else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do { pending = PendingImport(profile: try SettingsProfile.read(from: url)) } catch {
        model.message = "Couldn't import preferences: \(error.localizedDescription)"
      }
    }
  }
}

@MainActor struct SettingsProfilePreview: View {
  #if DEBUG
    var didAppear: ((Self) -> Void)?
  #endif
  @Bindable var model: AppModel
  let profile: SettingsProfile
  let close: () -> Void
  @State private var issue: String?
  var body: some View {
    let changes = profile.changes(from: model.settings)
    VStack(alignment: .leading, spacing: 16) {
      Text("Import preferences").font(.title2.bold())
      Text("Review changes before applying.")
      Text("Safety settings, automation, shortcuts and local files stay unchanged.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if changes.isEmpty {
        Text("These preferences already match this Mac.").foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(changes) { change in
              VStack(alignment: .leading, spacing: 4) {
                Text(change.label).font(.headline)
                HStack(alignment: .top) {
                  Text(change.before).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  Text("→").accessibilityHidden(true)
                  Text(change.after).frame(maxWidth: .infinity, alignment: .leading)
                }
              }.accessibilityElement(children: .combine)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 300)
      }
      if let issue {
        Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button("Apply preferences") {
          do {
            try model.applySettingsProfile(profile)
            close()
          } catch { issue = error.localizedDescription }
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(changes.isEmpty)
      }
    }
    .padding(24).frame(width: 550).background(.background)
    .onAppear {
      #if DEBUG
        didAppear?(self)
      #endif
    }
  }
}
