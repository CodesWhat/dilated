import AppKit
import SwiftUI

/// What the About page shows, read from the bundle with fallbacks for tests and `swift run`.
enum AboutInfo {
  static let repository = "https://github.com/CodesWhat/dilated"
  static let links: [(title: String, detail: String, url: URL)] = [
    ("Website", "dilated.app", URL(string: "https://dilated.app")!),
    ("Privacy policy", "dilated.app/privacy", URL(string: "https://dilated.app/privacy")!),
    ("Source on GitHub", "CodesWhat/dilated", URL(string: repository)!),
    ("Report an issue", "Bugs and requests on GitHub.", URL(string: repository + "/issues")!),
    ("License", "MIT.", URL(string: repository + "/blob/main/LICENSE")!),
    (
      "Third-party notices", "Fonts and adapted code.",
      URL(string: repository + "/blob/main/docs/THIRD-PARTY.md")!
    ),
  ]
  static let fallbackVersion = "Development build"
  static let fallbackCopyright = "Copyright © CodesWhat. Licensed under MIT."

  static func version(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
    func value(_ key: String) -> String? {
      guard let text = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else { return nil }
      return text
    }
    guard let version = value("DilatedDisplayVersion") ?? value("CFBundleShortVersionString")
    else { return fallbackVersion }
    guard let build = value("CFBundleVersion") else { return version }
    return "\(version) (\(build))"
  }

  static func copyright(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
    let text = (info?["NSHumanReadableCopyright"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text! : fallbackCopyright
  }
}

@MainActor struct AboutSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "DILATED") {
        HStack(spacing: 16) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text("Dilated").font(DesignFont.heading(26))
            Text(AboutInfo.version()).textSelection(.enabled)
              .foregroundStyle(DesignPalette.ink2)
            Text(AboutInfo.copyright()).font(DesignFont.sans(11.5))
              .foregroundStyle(DesignPalette.ink2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }.padding(12)
        #if !MAS_CHANNEL
          SettingsRow(title: "App updates", detail: model.updater.statusText) {
            Button("Check for Updates…") { model.updater.checkForUpdates() }
              .disabled(!model.updater.canCheckForUpdates)
          }
        #endif
      }
      SettingsGroup(eyebrow: "LINKS") {
        ForEach(AboutInfo.links, id: \.title) { link in
          SettingsRow(title: link.title, detail: link.detail) {
            Button("Open") { NSWorkspace.shared.open(link.url) }
              .accessibilityLabel("Open \(link.title)")
          }
        }
      }
      #if !MAS_CHANNEL
        Text(SupportLinks.credits).font(DesignFont.sans(11.5)).foregroundStyle(DesignPalette.ink2)
          .multilineTextAlignment(.center).frame(maxWidth: .infinity)
          .fixedSize(horizontal: false, vertical: true)
      #endif
    }
  }
}
