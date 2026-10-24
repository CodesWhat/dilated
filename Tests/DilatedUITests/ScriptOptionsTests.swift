import AppKit
import Testing

@testable import DilatedUI

@MainActor struct ScriptOptionsTests {
  private func record(_ text: String) throws -> NSAppleEventDescriptor {
    let script = try #require(NSAppleScript(source: "return \(text)"))
    var issue: NSDictionary?
    let value = script.executeAndReturnError(&issue)
    #expect(issue == nil)
    return value
  }

  @Test func realAppleScriptRecordsKeepUnitsAndBooleanTypes() throws {
    let minutes = try ScriptStartOptions.parse(
      record("{duration:5, interval:minutes, displaySleepAllowed:false}"))
    #expect(minutes.duration == 300)
    #expect(!minutes.usesDefaultDuration)
    #expect(minutes.displaySleepAllowed == false)
    let hours = try ScriptStartOptions.parse(record("{duration:2, interval:hours}"))
    #expect(hours.duration == 7200)
  }

  @Test func missingOptionsAndDisplayOnlyUseCurrentDuration() throws {
    #expect(try ScriptStartOptions.parse(nil).usesDefaultDuration)
    let display = try ScriptStartOptions.parse(record("{displaySleepAllowed:true}"))
    #expect(display.usesDefaultDuration)
    #expect(display.displaySleepAllowed == true)
    let indefinite = try ScriptStartOptions.parse(record("{duration:0, interval:0}"))
    #expect(!indefinite.usesDefaultDuration)
    #expect(indefinite.duration == nil)
  }

  @Test func recordLabelsFollowAppleScriptsCaseInsensitiveNames() throws {
    let options = try ScriptStartOptions.parse(
      record("{DURATION:5, INTERVAL:minutes, displaysleepallowed:false}"))
    #expect(options.duration == 300)
    #expect(options.displaySleepAllowed == false)
  }

  @Test func malformedPartialAndUnknownOptionsAreRejected() throws {
    for text in [
      "{duration:5}", "{interval:minutes}", "{extra:1}", "{duration:-1, interval:minutes}",
      "{duration:1.5, interval:minutes}", "{duration:true, interval:minutes}",
      "{duration:1, interval:false}", "{duration:0, interval:minutes}",
      "{duration:1, interval:0}", "{displaySleepAllowed:1}", "{displaySleepAllowed:\"yes\"}",
      "{duration:2147483647, interval:hours}", "{duration:1, interval:1.0E+300}",
      "{duration:1, interval:-60}", "5", "{1, 2}",
    ] {
      let value = try record(text)
      #expect(throws: (any Error).self) { try ScriptStartOptions.parse(value) }
    }
  }
}
