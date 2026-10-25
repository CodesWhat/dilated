import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct CustomGlyphSettingsView: View {
  @Bindable var model: AppModel
  @State private var preview: NSImage?
  @State private var idlePreview: NSImage?
  @State private var previewIssue: String?
  @State private var idlePreviewIssue: String?
  @State private var issue: String?
  @State private var importing = false
  var body: some View {
    SettingsGroup(
      eyebrow: "CUSTOM PNG",
      footer:
        "Static transparent PNGs, each up to 512 × 512 pixels and 2 MB. The idle PNG is optional; without one, the active PNG is used for both states. Colors follow the menu bar. Idle dimming is set below."
    ) {
      SettingsRow(
        title: model.settings.customGlyph?.name ?? "No active PNG",
        detail: previewIssue ?? "Active PNG"
      ) {
        if let preview {
          Image(nsImage: preview).resizable().interpolation(.none).frame(width: 32, height: 30)
            .accessibilityHidden(true)
        }
        Toggle("Use imported PNGs", isOn: $model.settings.useCustomGlyph)
          .labelsHidden().disabled(
            model.settings.customGlyph == nil && !model.settings.useCustomGlyph)
        Button("Import active PNG…") { choose(.active) }.disabled(importing)
        if model.settings.customGlyph != nil || model.settings.customIdleGlyph != nil {
          Button("Remove icons") {
            do {
              try model.removeCustomGlyph()
              issue = nil
            } catch { issue = error.localizedDescription }
          }.disabled(importing)
        }
      }
      SettingsRow(
        title: model.settings.customIdleGlyph?.name ?? "Use active PNG while idle",
        detail: idlePreviewIssue ?? "Idle PNG (optional)"
      ) {
        if let idlePreview {
          Image(nsImage: idlePreview).resizable().interpolation(.none).frame(width: 32, height: 30)
            .accessibilityHidden(true)
        }
        Button("Import idle PNG…") { choose(.idle) }
          .disabled(importing || model.settings.customGlyph == nil)
        if model.settings.customIdleGlyph != nil {
          Button("Remove idle PNG") {
            do {
              try model.removeCustomIdleGlyph()
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
      (preview, previewIssue) = load(model.settings.customGlyph)
    }.task(id: model.settings.customIdleGlyph?.id) {
      (idlePreview, idlePreviewIssue) = load(model.settings.customIdleGlyph)
    }
  }
  private func load(_ glyph: CustomGlyph?) -> (NSImage?, String?) {
    guard let glyph else { return (nil, nil) }
    do {
      return (try CustomGlyphStore(directory: model.endpoint.stateDirectory).image(glyph), nil)
    } catch { return (nil, "The saved PNG couldn't be loaded. Import it again.") }
  }
  private func choose(_ variant: CustomGlyphVariant) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = variant == .active ? "Use active icon" : "Use idle icon"
    importing = true
    panel.begin { response in
      guard response == .OK, let file = panel.url else {
        importing = false
        return
      }
      Task {
        defer { importing = false }
        do {
          try await model.importCustomGlyph(from: file, variant: variant)
          issue = nil
        } catch { issue = error.localizedDescription }
      }
    }
  }
}
