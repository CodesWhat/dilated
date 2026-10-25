import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct CustomGlyphSettingsView: View {
  @Bindable var model: AppModel
  @State private var preview: NSImage?
  @State private var issue: String?
  @State private var importing = false
  var body: some View {
    SettingsGroup(
      eyebrow: "CUSTOM PNG",
      footer:
        "One static PNG with a transparent background, up to 512 × 512 pixels and 2 MB. Colors follow the menu bar. Imported icons dim when idle by default; change that below."
    ) {
      SettingsRow(title: model.settings.customGlyph?.name ?? "No imported icon") {
        if let preview {
          Image(nsImage: preview).resizable().interpolation(.none).frame(width: 32, height: 30)
            .accessibilityHidden(true)
        }
        Toggle("Use imported PNG", isOn: $model.settings.useCustomGlyph)
          .labelsHidden().disabled(
            model.settings.customGlyph == nil && !model.settings.useCustomGlyph)
        Button("Import PNG…", action: choose).disabled(importing)
        if model.settings.customGlyph != nil {
          Button("Remove") {
            do {
              try model.removeCustomGlyph()
              issue = nil
            } catch { issue = error.localizedDescription }
          }.disabled(importing)
        }
      }
      if let issue { SettingsNote(text: issue, tone: DesignPalette.danger) }
      if let issue = model.customGlyphIssue {
        SettingsNote(text: issue, tone: DesignPalette.danger)
      }
    }.task(id: model.settings.customGlyph?.id) {
      preview = nil
      guard let glyph = model.settings.customGlyph else { return }
      do {
        preview = try CustomGlyphStore(directory: model.endpoint.stateDirectory).image(glyph)
      } catch {
        issue =
          "The imported file couldn't be loaded. Import the PNG again or choose a bundled icon."
      }
    }
  }
  private func choose() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = "Use icon"
    panel.begin { response in
      guard response == .OK, let file = panel.url else { return }
      importing = true
      Task {
        defer { importing = false }
        do {
          try await model.importCustomGlyph(from: file)
          issue = nil
        } catch { issue = error.localizedDescription }
      }
    }
  }
}
