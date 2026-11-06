import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

struct DurationInputTests {
  @Test func phrasesAndLeaseDurationAliasMatchNumericInput() throws {
    let numeric = try CLIInput.parse(["hold", "--ttl", "90m"])
    let phrase = try CLIInput.parse(["hold", "--for", "for 1 hour 30 minutes"])
    #expect(phrase.request?.action == numeric.request?.action)
    #expect(phrase.request?.duration == numeric.request?.duration)
    #expect(try CLIInput.parse(["on", "--for", "2h30"]).request?.duration == 9000)
  }

  @Test func ambiguousOrConflictingInputsAreRejected() {
    for args in [
      ["hold", "--for", "until 5"],
      ["hold", "--for", "1h", "--ttl", "30m"],
      ["on", "--for", "1 hour", "--until", "17:00"],
    ] {
      #expect(throws: (any Error).self) { try CLIInput.parse(args) }
    }
  }

  @Test func deadlinePhrasesUseTheChosenCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-05T15:00:00Z"))
    #expect(try TimeInput.sessionDuration("until 5pm", now: now, calendar: calendar) == 7200)
    #expect(
      try TimeInput.sessionDuration("until tomorrow 9am", now: now, calendar: calendar) == 64800)
  }

  @Test func existingLongNumericDurationsKeepTheirLimit() throws {
    #expect(try CLIInput.parse(["hold", "--ttl", "200h"]).request?.duration == 720000)
  }
}
