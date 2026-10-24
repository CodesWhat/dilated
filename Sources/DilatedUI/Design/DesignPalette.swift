// Adapted from CodesWhat/Mouthtype, authored by Scott Benson, relicensed under MIT.
import AppKit
import SwiftUI

/// Gas Station uses yellow, red and warm paper grounds, with adaptive ink for dark appearance.
enum DesignPalette {
  // MARK: Adaptive colours

  enum NS {
    static let bg = pair(light: 0xF8F5EA, dark: 0x211F1A)
    static let surface = pair(light: 0xFFFCF3, dark: 0x2D2922)
    static let ink = pair(light: 0x29251C, dark: 0xFFF9E8)
    static let ink2 = pair(
      light: 0x645D4B, dark: 0xC5BBA5, contrastLight: 0x3A352A, contrastDark: 0xE5DDCC)
    static let ink3 = pair(
      light: 0x6E6550, dark: 0xAEA38B, contrastLight: 0x454032, contrastDark: 0xD8CFBA)
    static let hair = pair(
      light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.14), contrastLight: (0, 0, 0, 0.45),
      contrastDark: (1, 1, 1, 0.5))
    static let hair2 = pair(
      light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.08), contrastLight: (0, 0, 0, 0.3),
      contrastDark: (1, 1, 1, 0.34))
    static let accent = pair(light: 0xFFDF24, dark: 0xFFDF24)
    static let accentSoft = pair(light: 0xFFF2A0, dark: 0x493E12)
    /// Non-text accent: edges, small dots, thin bars and strokes. 3:1 or better on every surface it sits on.
    static let accentMark = pair(light: 0xB91C27, dark: 0xFFDF24)
    static let onAccent = pair(light: 0x272218, dark: 0x272218)
    static let accentText = pair(light: 0xB91C27, dark: 0xFFDF24)
    static let focus = pair(light: 0xB91C27, dark: 0xFFDF24)
    /// The secondary (--accent-2). Reserved for the lips, the streak flame and warnings.
    static let orange = pair(light: 0xE37512, dark: 0xF19A4B)
    static let success = pair(light: 0x537F5D, dark: 0x6FA57C)
    static let danger = pair(light: 0xD70015, dark: 0xFF564C)
    // High scores. Gold, silver and bronze mark ranks; personal best is a warm chip.
    static let gold = pair(light: 0xBB8C1A, dark: 0xF2B83D)
    static let silver = pair(light: 0x8F939D, dark: 0xC4C6CC)
    static let bronze = pair(light: 0xB8733A, dark: 0xD98C4F)
    static let personalBest = pair(light: 0xFBE9D3, dark: 0x3A2B1B)
    static let personalBestInk = pair(light: 0x6B3A0A, dark: 0xF5C28F)
    static let sel = pair(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.10))
    static let c0 = pair(light: 0xEFF4E4, dark: 0x373E2A)
    static let c1 = pair(light: 0xBFD5F2, dark: 0x556535)
    static let c2 = pair(light: 0x76A11A, dark: 0x779041)
    static let c3 = pair(light: 0x5C7E14, dark: 0xA8C8F2)
    static let c4 = pair(light: 0x3B4F0E, dark: 0xDBEBBA)
    static let track = pair(light: 0xD9D9DE, dark: 0x3C3C40)
    static let key = pair(light: 0xFFFFFF, dark: 0x38383B)
    static let scrim = pair(light: (0, 0, 0, 0.3), dark: (0, 0, 0, 0.5))
    static let sideBase = NSColor.windowBackgroundColor
    static let sideInk = NSColor.labelColor
    static let sideSelection = pair(light: 0xB91C27, dark: 0xB91C27)

  }

  static let bg = Color(nsColor: NS.bg)
  static let surface = Color(nsColor: NS.surface)
  static let ink = Color(nsColor: NS.ink)
  static let ink2 = Color(nsColor: NS.ink2)
  static let ink3 = Color(nsColor: NS.ink3)
  static let sideInk = Color(nsColor: NS.sideInk)
  static let sideSelection = Color(nsColor: NS.sideSelection)
  static let hair = Color(nsColor: NS.hair)
  static let hair2 = Color(nsColor: NS.hair2)
  static let accent = Color(nsColor: NS.accent)
  static let accentSoft = Color(nsColor: NS.accentSoft)
  static let onAccent = Color(nsColor: NS.onAccent)
  static let accentMark = Color(nsColor: NS.accentMark)
  static let accentText = Color(nsColor: NS.accentText)
  static let focus = Color(nsColor: NS.focus)
  static let orange = Color(nsColor: NS.orange)
  static let success = Color(nsColor: NS.success)
  static let danger = Color(nsColor: NS.danger)
  static let gold = Color(nsColor: NS.gold)
  static let silver = Color(nsColor: NS.silver)
  static let bronze = Color(nsColor: NS.bronze)
  static let personalBest = Color(nsColor: NS.personalBest)
  static let personalBestInk = Color(nsColor: NS.personalBestInk)
  static let sel = Color(nsColor: NS.sel)
  static let c0 = Color(nsColor: NS.c0)
  static let c1 = Color(nsColor: NS.c1)
  static let c2 = Color(nsColor: NS.c2)
  static let c3 = Color(nsColor: NS.c3)
  static let c4 = Color(nsColor: NS.c4)
  static let track = Color(nsColor: NS.track)
  static let key = Color(nsColor: NS.key)
  static let scrim = Color(nsColor: NS.scrim)
  /// The chart ramp, one lime hue from light (c0) to dark. Charts draw non-highlighted marks in `track`, not from this ramp.
  static let chart: [Color] = [c0, c1, c2, c3, c4]

  /// Chart marks that are not the highlight: grey, so the accent only ever marks the peak or the current item.
  static let neutralMark = ink3.opacity(0.55)

  /// The card drop shadow (`--shadow`).
  static func shadowColor(dark: Bool) -> Color { Color.black.opacity(dark ? 0.3 : 0.05) }

  // MARK: Builders

  private typealias RGBA = (CGFloat, CGFloat, CGFloat, CGFloat)

  private static func hex(_ value: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  private static func rgba(_ value: RGBA, bytes: Bool) -> NSColor {
    let scale: CGFloat = bytes ? 255 : 1
    return NSColor(
      srgbRed: value.0 / scale, green: value.1 / scale, blue: value.2 / scale, alpha: value.3)
  }

  private static func pair(
    light: Int, dark: Int, contrastLight: Int? = nil, contrastDark: Int? = nil
  ) -> NSColor {
    let (l, d) = (hex(light), hex(dark))
    let (cl, cd) = (contrastLight.map(hex) ?? l, contrastDark.map(hex) ?? d)
    return NSColor(name: nil) { appearance in
      let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
    }
  }

  private static func pair(
    light: RGBA, dark: RGBA, contrastLight: RGBA? = nil, contrastDark: RGBA? = nil,
    bytes: Bool = false
  ) -> NSColor {
    let (l, d) = (rgba(light, bytes: bytes), rgba(dark, bytes: bytes))
    let (cl, cd) = (
      contrastLight.map { rgba($0, bytes: bytes) } ?? l,
      contrastDark.map { rgba($0, bytes: bytes) } ?? d
    )
    return NSColor(name: nil) { appearance in
      let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
    }
  }
}

extension NSAppearance {
  var isDarkAqua: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

struct DesignSidebarBackground: View {
  var solid: Bool

  var body: some View {
    Color(nsColor: solid ? DesignPalette.NS.sideBase : .clear)
  }
}
