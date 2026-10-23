// Adapted from CodesWhat/Mouthtype, authored by Scott Benson, relicensed under MIT.
import AppKit
import SwiftUI

/// Colours, type and spacing for Dilated's control panel.
enum SettingsTheme {
  static let controlNS = DesignPalette.NS.accentMark
  static let control = Color(nsColor: controlNS)

  static let windowSize = NSSize(width: 900, height: 620)
  static let minimumSize = NSSize(width: 860, height: 600)
  static let sidebarWidth: CGFloat = 212
  static let headerHeight: CGFloat = 46
  static let rowMinHeight: CGFloat = 36
  static let rowLabelWidth: CGFloat = 220
}

/// Every point size the Settings window uses. Nothing may go below `minimum`.
enum SettingsFont {
  static let minimum: CGFloat = 10
  static let sansName = FontRegistry.sansNames[0]
  static let displayName = FontRegistry.displayName
  static let monoName = FontRegistry.monoName

  static let wordmark: CGFloat = 28
  static let title: CGFloat = 22
  static let headerDescription: CGFloat = 12.5
  static let body: CGFloat = 13
  static let detail: CGFloat = 11.5
  static let eyebrow: CGFloat = 10
  static let footer: CGFloat = 10

  static let all: [CGFloat] = [wordmark, title, headerDescription, body, detail, eyebrow, footer]

  static func sans(_ size: CGFloat) -> Font { .custom(sansName, size: max(size, minimum)) }
  static func heading(_ size: CGFloat) -> Font { .custom(displayName, size: max(size, minimum)) }
  static func mono(_ size: CGFloat) -> Font { .custom(monoName, size: max(size, minimum)) }
}

/// One row of a grouped form: title and optional detail on the left, controls on the right. Text wraps, never truncates.
/// The label column keeps at least `rowLabelWidth`; when the controls don't fit beside it they wrap below the label.
/// Callers keep buttons and popups at their intrinsic size with `.fixedSize()`; nothing is elided, the row grows or wraps instead.
struct SettingsRow<Controls: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var controls: () -> Controls

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(SettingsFont.sans(SettingsFont.body)).fixedSize(
        horizontal: false, vertical: true)
      if let detail, !detail.isEmpty {
        Text(detail).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(
          DesignPalette.ink2
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var controlRow: some View { HStack(spacing: 8) { controls() } }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 14) {
        label.frame(
          minWidth: SettingsTheme.rowLabelWidth, idealWidth: SettingsTheme.rowLabelWidth,
          maxWidth: .infinity, alignment: .leading)
        controlRow.layoutPriority(1)
      }
      VStack(alignment: .leading, spacing: 6) {
        label.frame(maxWidth: .infinity, alignment: .leading)
        controlRow
      }
    }
    .frame(minHeight: SettingsTheme.rowMinHeight - 8)
  }
}

/// Plain secondary text row inside a group (notes, warnings), wrapping at any width.
struct SettingsNote: View {
  let text: String
  var tone: Color = .secondary

  var body: some View {
    Text(text).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(tone)
      .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Labelled control rows with the printed rules and square corners of the Gas Station pack.
struct SettingsGroup<Content: View>: View {
  let eyebrow: String
  var footer: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(eyebrow).font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1)
        .foregroundStyle(DesignPalette.accentText)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.accentSoft).accessibilityAddTraits(.isHeader)
      Rectangle().fill(DesignPalette.hair).frame(height: 1)
      Group(subviews: content()) { rows in
        VStack(spacing: 0) {
          ForEach(rows.indices, id: \.self) { index in
            if index > 0 {
              Rectangle().fill(DesignPalette.hair2).frame(height: 1).padding(.horizontal, 12)
            }
            rows[index].padding(.horizontal, 12).padding(.vertical, 8)
          }
        }
      }
      .background(DesignPalette.surface)
      if let footer {
        Text(footer).font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(
          DesignPalette.ink2
        )
        .fixedSize(horizontal: false, vertical: true).padding(12)
      }
    }
    .background(DesignPalette.surface).clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesignPalette.hair, lineWidth: 1))
  }
}

/// Set false by `DesignPage`, which owns the scrolling, so a hosted `SettingsForm` page lays out in place instead of nesting a scroll view.
extension EnvironmentValues {
  @Entry var settingsFormScrolls = true
}

/// The scrolling page body: groups stacked 14 pt apart. Inside a `DesignPage` it only stacks, with no margins of its own.
struct SettingsForm<Content: View>: View {
  @Environment(\.settingsFormScrolls) private var scrolls
  @ViewBuilder var content: () -> Content

  var body: some View {
    if scrolls {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) { content() }
          .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16).frame(
            maxWidth: .infinity, alignment: .leading)
      }
    } else {
      VStack(alignment: .leading, spacing: 14) { content() }.frame(
        maxWidth: .infinity, alignment: .leading)
    }
  }
}
