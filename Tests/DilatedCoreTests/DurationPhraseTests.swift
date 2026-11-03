import Foundation
import Testing

@testable import DilatedCore

struct DurationPhraseTests {
  private func calendar(_ zone: String = "America/New_York", locale: String = "en_US") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: locale)
    return calendar
  }

  private func date(
    _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
  ) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private let durationCases: [(String, TimeInterval)] = [
    ("for 90m", 5400), ("90m", 5400), ("90 minutes", 5400), ("90 min", 5400), ("1 minute", 60),
    ("for 2 hours", 7200), ("1.5h", 5400), ("30s", 30), ("45 seconds", 45),
    ("2h30", 9000), ("1h 15m", 4500), ("1h15m", 4500), ("1h 15", 4500),
    ("2 hours 30 minutes", 9000),
    ("  FOR   1H  ", 3600), ("168h", 604_800), ("7 hours 59 minutes 59 seconds", 28799),
  ]

  @Test func parsesDurations() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    for (text, seconds) in durationCases {
      #expect(DurationPhrase.parse(text, now: now, calendar: cal) == .duration(seconds), "\(text)")
    }
  }

  @Test func sharesTheCLIGrammarForCompactDurations() throws {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    for text in ["90m", "1.5h", "30s", "2h"] {
      #expect(
        DurationPhrase.parse(text, now: now, calendar: cal)
          == .duration(try TimeInput.duration(text)))
    }
  }

  @Test func rejectsBadDurations() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    let cases: [(String, DurationPhrase.Rejection)] = [
      ("", .empty), ("   ", .empty),
      ("5", .missingUnit), ("for 90", .missingUnit), ("1.5", .missingUnit),
      ("0m", .notPositive), ("0 minutes", .notPositive), ("-5m", .notPositive),
      ("for -1h", .notPositive),
      ("169h", .tooLong), ("8 days", .unknownUnit("days")), ("7d", .unknownUnit("d")),
      ("3 fortnights", .unknownUnit("fortnights")), ("10000h", .tooLong),
      ("15m 1h", .unrecognized), ("1h 1h", .unrecognized), ("1.5h 30m", .unrecognized),
      ("2h75", .missingUnit), ("2h30m15", .missingUnit), ("1h 1.5", .missingUnit),
      ("soon", .unrecognized), ("for", .unrecognized), ("1h junk", .unrecognized),
    ]
    for (text, reason) in cases {
      #expect(DurationPhrase.parse(text, now: now, calendar: cal) == .rejected(reason), "\(text)")
    }
  }

  @Test func resolvesDeadlinesOn12HourClock() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    let cases: [(String, Date)] = [
      ("until 5pm", date(cal, 2026, 11, 3, 17)),
      ("until 5 PM", date(cal, 2026, 11, 3, 17)),
      ("until 5:30pm", date(cal, 2026, 11, 3, 17, 30)),
      ("until 5:30 p.m.", date(cal, 2026, 11, 3, 17, 30)),
      ("until 12pm", date(cal, 2026, 11, 4, 12, 0)),
      ("until 17:30", date(cal, 2026, 11, 3, 17, 30)),
      ("until noon", date(cal, 2026, 11, 4, 12)),
      ("until midnight", date(cal, 2026, 11, 4, 0)),
      ("until 12am", date(cal, 2026, 11, 4, 0)),
      ("until tomorrow 9am", date(cal, 2026, 11, 4, 9)),
      ("until 9am tomorrow", date(cal, 2026, 11, 4, 9)),
      ("until today 5pm", date(cal, 2026, 11, 3, 17)),
      ("until tomorrow 17:30", date(cal, 2026, 11, 4, 17, 30)),
    ]
    for (text, expected) in cases {
      #expect(DurationPhrase.parse(text, now: now, calendar: cal) == .deadline(expected), "\(text)")
    }
  }

  @Test func resolvesDeadlinesOn24HourClock() {
    let cal = calendar("Europe/Berlin", locale: "de_DE")
    let now = date(cal, 2026, 11, 3, 12)
    #expect(DurationPhrase.uses24HourClock(cal))
    let cases: [(String, Date)] = [
      ("until 17:30", date(cal, 2026, 11, 3, 17, 30)),
      ("until 5:30", date(cal, 2026, 11, 4, 5, 30)),
      ("until 09:00", date(cal, 2026, 11, 4, 9)),
      ("until 5pm", date(cal, 2026, 11, 3, 17)),
      ("until 00:15", date(cal, 2026, 11, 4, 0, 15)),
    ]
    for (text, expected) in cases {
      #expect(DurationPhrase.parse(text, now: now, calendar: cal) == .deadline(expected), "\(text)")
    }
  }

  @Test func clockAmbiguityDependsOnTheLocale() {
    let us = calendar()
    let de = calendar("Europe/Berlin", locale: "de_DE")
    #expect(!DurationPhrase.uses24HourClock(us))
    let now = date(us, 2026, 11, 3, 12)
    #expect(
      DurationPhrase.parse("until 5:30", now: now, calendar: us) == .rejected(.ambiguousClock))
    #expect(
      DurationPhrase.parse("until 09:00", now: now, calendar: us) == .rejected(.ambiguousClock))
    #expect(
      DurationPhrase.parse("until 5:30", now: now, calendar: de) != .rejected(.ambiguousClock))
  }

  @Test func rejectsBadDeadlines() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    let cases: [(String, DurationPhrase.Rejection)] = [
      ("until", .empty), ("until ", .empty),
      ("until 5", .ambiguousClock), ("until 17", .ambiguousClock),
      ("until 13pm", .invalidClock), ("until 0am", .invalidClock), ("until 0pm", .invalidClock),
      ("until 25:00", .invalidClock), ("until 24:00", .invalidClock),
      ("until 9:60am", .invalidClock),
      ("until 5:7pm", .unrecognized), ("until later", .unrecognized),
      ("until tomorrow", .unrecognized),
      ("until today", .unrecognized), ("until tomorrow tomorrow", .unrecognized),
      ("until today 9am", .alreadyPassed), ("until today 12pm", .alreadyPassed),
    ]
    for (text, reason) in cases {
      #expect(DurationPhrase.parse(text, now: now, calendar: cal) == .rejected(reason), "\(text)")
    }
  }

  @Test func aTimeAlreadyPassedTodayMeansTomorrow() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 15)
    #expect(
      DurationPhrase.parse("until 9am", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 11, 4, 9)))
    #expect(
      DurationPhrase.parse("until 3pm", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 11, 4, 15)))
    #expect(
      DurationPhrase.parse("until 3:01pm", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 11, 3, 15, 1)))
  }

  @Test func midnightRollover() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 23)
    #expect(
      DurationPhrase.parse("until 1am", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 11, 4, 1)))
    #expect(
      DurationPhrase.parse("until 01:00", now: now, calendar: calendar(locale: "en_GB"))
        == .deadline(date(cal, 2026, 11, 4, 1)))
    let lateMonth = date(cal, 2026, 12, 31, 23, 30)
    #expect(
      DurationPhrase.parse("until 12:15am", now: lateMonth, calendar: cal)
        == .deadline(date(cal, 2027, 1, 1, 0, 15)))
    #expect(
      DurationPhrase.parse("until tomorrow 9am", now: lateMonth, calendar: cal)
        == .deadline(date(cal, 2027, 1, 1, 9)))
  }

  @Test func springForwardKeepsWallClockTimes() {
    // 2026-03-08: 02:00 EST jumps to 03:00 EDT.
    let cal = calendar()
    let now = date(cal, 2026, 3, 7, 22)
    // 9am on the 8th is only 10 elapsed hours after 10pm.
    guard case .deadline(let nine) = DurationPhrase.parse("until 9am", now: now, calendar: cal)
    else {
      Issue.record("expected a deadline")
      return
    }
    #expect(nine == date(cal, 2026, 3, 8, 9))
    #expect(nine.timeIntervalSince(now) == 10 * 3600)
    // A wall-clock time that doesn't exist moves to the first instant after the gap (3:00) rather than failing or landing on another day.
    #expect(
      DurationPhrase.parse("until 2:30am", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 3, 8, 3)))
    #expect(
      DurationPhrase.parse("until tomorrow 2:30am", now: now, calendar: cal)
        == .deadline(date(cal, 2026, 3, 8, 3)))
    // Durations are elapsed time, so they ignore the jump.
    #expect(DurationPhrase.parse("for 8h", now: now, calendar: cal) == .duration(8 * 3600))
  }

  @Test func fallBackUsesTheFirstRepeatedHour() {
    // 2026-11-01: 02:00 EDT falls back to 01:00 EST, so 1:30am happens twice.
    let cal = calendar()
    let now = date(cal, 2026, 10, 31, 22)
    guard case .deadline(let first) = DurationPhrase.parse("until 1:30am", now: now, calendar: cal)
    else {
      Issue.record("expected a deadline")
      return
    }
    #expect(first.timeIntervalSince(now) == 3.5 * 3600)
    // 9am on the 1st is 12 elapsed hours after 10pm, because the day is an hour longer.
    guard case .deadline(let nine) = DurationPhrase.parse("until 9am", now: now, calendar: cal)
    else {
      Issue.record("expected a deadline")
      return
    }
    #expect(nine.timeIntervalSince(now) == 12 * 3600)
    // Already inside the repeated hour: the next 1:30am is the following day, not the second pass.
    let secondPass = first.addingTimeInterval(3600)
    guard
      case .deadline(let next) = DurationPhrase.parse(
        "until 1:30am", now: secondPass, calendar: cal)
    else {
      Issue.record("expected a deadline")
      return
    }
    #expect(next == date(cal, 2026, 11, 2, 1, 30))
  }

  @Test func deadlinesPastTheLimitAreRejected() {
    let cal = calendar()
    let now = date(cal, 2026, 11, 3, 12)
    // "tomorrow" can never exceed 48 hours, so the limit is exercised through the shared maximum instead.
    #expect(DurationPhrase.maximumSeconds == 7 * 86400)
    #expect(
      DurationPhrase.parse("for 168h", now: now, calendar: cal)
        == .duration(DurationPhrase.maximumSeconds))
    #expect(DurationPhrase.parse("for 169h", now: now, calendar: cal) == .rejected(.tooLong))
  }
}
