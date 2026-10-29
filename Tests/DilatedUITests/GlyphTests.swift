import AppKit
import Testing

@testable import DilatedUI

@MainActor struct GlyphTests {
  @Test func awakeEyesGlanceBothWaysThenRest() {
    let glyph = Glyph.bugEyes
    func frame(_ elapsed: TimeInterval, _ motion: Motion = .subtle) -> String {
      glyph.frame(awake: true, elapsed: elapsed, motion: motion, reduceMotion: false)
    }
    #expect(frame(0) == glyph.stillFrame)
    #expect(frame(0.4) == "look-left")
    #expect(frame(1.2) == "look-right")
    #expect(frame(2.5) == glyph.stillFrame)
    #expect(frame(5.4) == glyph.stillFrame)
    #expect(frame(5.4, .lively) == "look-left")
    #expect(frame(10.4) == "look-left")
    for elapsed in [0.4, 1.2, 5.4, 10.4] {
      #expect(
        glyph.frame(awake: false, elapsed: elapsed, motion: .lively, reduceMotion: false) == "off")
      #expect(
        glyph.frame(awake: true, elapsed: elapsed, motion: .off, reduceMotion: false)
          == glyph.stillFrame)
      #expect(
        glyph.frame(awake: true, elapsed: elapsed, motion: .lively, reduceMotion: true)
          == glyph.stillFrame)
    }
  }

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

  @Test func repeatedImageRequestsReturnTheSameInstance() throws {
    for glyph in Glyph.allCases {
      for frame in glyph.frames {
        let first = try #require(glyph.image(frame: frame))
        let second = try #require(glyph.image(frame: frame))
        #expect(first === second)
      }
    }
  }

  @Test func animatesOnlyWhenMotionIsOnAndTheGlyphHasMoreThanOneAwakeFrame() {
    let elapsedValues: [TimeInterval] = [0, 0.2, 0.5, 1.2, 4.1, 8.1, 100]
    for glyph in Glyph.allCases {
      for motion in Motion.allCases {
        for reduceMotion in [false, true] {
          let animates = glyph.animates(motion: motion, reduceMotion: reduceMotion)
          let expected = motion != .off && !reduceMotion && glyph != .catCans
          #expect(animates == expected)
          if !animates {
            let frames = Set(
              elapsedValues.map {
                glyph.frame(awake: true, elapsed: $0, motion: motion, reduceMotion: reduceMotion)
              })
            #expect(frames.count == 1)
          }
        }
      }
    }
    for glyph in [Glyph.bugEyes, .can, .spiralEyes] {
      #expect(glyph.animates(motion: .subtle, reduceMotion: false))
      #expect(glyph.animates(motion: .lively, reduceMotion: false))
    }
  }
}
