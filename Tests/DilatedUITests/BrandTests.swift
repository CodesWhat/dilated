import AppKit
import Testing

@testable import DilatedUI

@MainActor struct BrandTests {
  @Test func nativeTypeUsesTheGasStationFamiliesWithoutFallback() throws {
    FontRegistry.resetForTesting()
    let families = FontRegistry.registerBundledFonts()
    #expect(families.contains("Barlow"))
    #expect(families.contains("Barlow Condensed"))
    for name in [
      "Barlow-Regular", "Barlow-Medium", "Barlow-SemiBold", "BarlowCondensed-ExtraBold",
      "BarlowCondensed-ExtraBoldItalic",
    ] {
      let font = try #require(NSFont(name: name, size: 16))
      #expect(font.familyName?.hasPrefix("Barlow") == true)
    }
    #expect(
      !FontRegistry.fontURLs(in: .module).contains { $0.lastPathComponent.hasPrefix("Instrument") })
  }

  @Test func textAndControlsKeepContrastInBothAppearances() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try #require(NSAppearance(named: name))
      appearance.performAsCurrentDrawingAppearance {
        #expect(contrast(DesignPalette.NS.ink, DesignPalette.NS.bg) >= 4.5)
        #expect(contrast(DesignPalette.NS.ink2, DesignPalette.NS.surface) >= 4.5)
        #expect(contrast(SettingsTheme.controlNS, DesignPalette.NS.surface) >= 3)
        #expect(contrast(DesignPalette.NS.onAccent, DesignPalette.NS.accent) >= 4.5)
      }
    }
  }

  private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
      let rgb = color.usingColorSpace(.sRGB)!
      func channel(_ value: CGFloat) -> Double {
        let value = Double(value)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722
        * channel(rgb.blueComponent)
    }
    let values = [luminance(a), luminance(b)].sorted()
    return (values[1] + 0.05) / (values[0] + 0.05)
  }
}
