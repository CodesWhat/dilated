import AppKit
import Testing

@testable import DilatedUI

@MainActor struct GlyphTests {
  @Test func everyGlyphLoadsAtBothResolutionsAndHonorsReduceMotion() throws {
    for glyph in Glyph.allCases {
      for frame in glyph.frames {
        let image = try #require(glyph.image(frame: frame))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 16, height: 15))
        #expect(image.representations.count == 2)
      }
      #expect(
        glyph.frame(awake: false, elapsed: 1, motion: .lively, reduceMotion: false).contains("off"))
      #expect(
        glyph.frame(awake: true, elapsed: 0, motion: .lively, reduceMotion: true)
          == glyph.stillFrame)
      #expect(
        glyph.frame(awake: true, elapsed: 0.2, motion: .off, reduceMotion: false)
          == glyph.stillFrame)
    }
  }
}
