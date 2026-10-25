import AppKit
import DilatedControl
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct SessionTimeTests {
  @Test func missingUnknownAndMalformedTimeAppearancePreserveMacAndStandardDefaults() throws {
    for json in [
      #"{"countdown":true,"swapClicks":true}"#,
      #"{"countdown":true,"swapClicks":true,"countdownHourCycle":"future","countdownTextSize":"future"}"#,
      #"{"countdown":true,"swapClicks":true,"countdownHourCycle":7,"countdownTextSize":{}}"#,
    ] {
      let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
      #expect(settings.countdown && settings.swapClicks)
      #expect(settings.countdownHourCycle == .system && settings.countdownTextSize == .standard)
    }
    var settings = AppSettings()
    settings.countdownHourCycle = .twentyFourHour
    settings.countdownTextSize = .small
    #expect(
      try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
  }

  @Test func endTimeOverridesHourCycleAcrossLocalesWithoutChangingCountdownDurations() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 13, minute: 4)))
    let date = now.addingTimeInterval(60)
    for locale in [Locale(identifier: "en_US_POSIX"), Locale(identifier: "en_GB")] {
      let twelve = CountdownFormat.endTime.remaining(
        until: date, now: now, hourCycle: .twelveHour, locale: locale, calendar: calendar)
      let twentyFour = CountdownFormat.endTime.remaining(
        until: date, now: now, hourCycle: .twentyFourHour, locale: locale, calendar: calendar)
      #expect(twelve.contains("1:05") && twelve.lowercased().contains("pm"))
      #expect(twentyFour == "13:05")
    }
    for mode in CountdownHourCycle.allCases {
      #expect(CountdownFormat.clock.remaining(until: date, now: now, hourCycle: mode) == "1:00")
      #expect(CountdownFormat.compact.remaining(until: date, now: now, hourCycle: mode) == "1m")
    }
  }

  @Test func hourCycleKeepsLocalizedDigitsMidnightDateAndSeconds() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 59)))
    let date = now.addingTimeInterval(6 * 60)
    let locale = Locale(identifier: "en_US_POSIX")
    let twentyFour = CountdownFormat.endTime.remaining(
      until: date, now: now, seconds: .show, hourCycle: .twentyFourHour, locale: locale,
      calendar: calendar)
    #expect(twentyFour.contains("Oct 26") && twentyFour.contains("00:05:00"))
    let twelve = CountdownFormat.endTime.remaining(
      until: date, now: now, seconds: .hide, hourCycle: .twelveHour, locale: locale,
      calendar: calendar)
    #expect(twelve.contains("12:05") && twelve.contains("AM"))
    let arabic = CountdownFormat.endTime.remaining(
      until: date, now: now, seconds: .hide, hourCycle: .twentyFourHour,
      locale: Locale(identifier: "ar_EG@numbers=arab"), calendar: calendar)
    #expect(arabic.contains("٠٠:٠٥"))
  }

  @Test func menuTextSizePersistsAndKeepsAttentionReadableWhenTimeIsHidden() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.settings.countdown = true
    model.settings.countdownTextSize = .small
    model.settings.countdownHourCycle = .twentyFourHour
    model.start()
    model.message = "Helper needs attention."
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    let button = try #require(controller.statusItem.button)
    #expect(button.font?.pointSize == 11)
    #expect(button.attributedTitle.string == " ! ∞")
    let attention = try #require(
      button.attributedTitle.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
    #expect(attention.pointSize == 12)
    #expect(
      button.attributedTitle.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        == DesignPalette.NS.orange)
    model.settings.countdown = false
    controller.refresh()
    #expect(button.attributedTitle.string == " !")
    model.settings.countdownTextSize = .standard
    controller.refresh()
    #expect(button.font?.pointSize == 12)
    let restored = try JSONDecoder().decode(
      AppSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    #expect(
      restored.countdownHourCycle == .twentyFourHour && restored.countdownTextSize == .standard)
  }

  @Test func missingAndUnknownSecondsPreserveExistingFormats() throws {
    for json in [
      #"{"countdownFormat":"clock"}"#, #"{"countdownFormat":"clock","countdownSeconds":"future"}"#,
    ] {
      let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
      #expect(settings.countdownSeconds == .automatic)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(
      CountdownFormat.compact.remaining(
        until: now.addingTimeInterval(61), now: now, seconds: .automatic) == "2m")
    #expect(
      CountdownFormat.compact.remaining(
        until: now.addingTimeInterval(59), now: now, seconds: .automatic) == "59s")
    #expect(
      CountdownFormat.clock.remaining(
        until: now.addingTimeInterval(61), now: now, seconds: .automatic) == "1:01")
  }

  @Test func secondsCanBeShownOrHiddenWithoutUnderstatingTimeLeft() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (amount, compact, clock) in [
      (0.0, "0m", "0:00"), (0.1, "1m", "0:01"), (59, "1m", "0:01"), (60.1, "2m", "0:02"),
      (3599.1, "1h 0m", "1:00"),
    ] {
      #expect(
        CountdownFormat.compact.remaining(
          until: now.addingTimeInterval(amount), now: now, seconds: .hide) == compact)
      #expect(
        CountdownFormat.clock.remaining(
          until: now.addingTimeInterval(amount), now: now, seconds: .hide) == clock)
    }
    #expect(
      CountdownFormat.compact.remaining(
        until: now.addingTimeInterval(3661), now: now, seconds: .show) == "1h 1m 1s")
    #expect(
      CountdownFormat.compact.remaining(until: now.addingTimeInterval(61), now: now, seconds: .show)
        == "1m 1s")
    #expect(
      CountdownFormat.clock.remaining(until: now.addingTimeInterval(61), now: now, seconds: .show)
        == "1:01")
  }

  @Test func endTimeUsesTheSelectedCalendarAndIncludesTheDateAcrossMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let locale = Locale(identifier: "en_US_POSIX")
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 30)))
    let sameDay = now.addingTimeInterval(60)
    let tomorrow = now.addingTimeInterval(3600)
    let short = CountdownFormat.endTime.remaining(
      until: sameDay, now: now, seconds: .hide, locale: locale, calendar: calendar)
    let precise = CountdownFormat.endTime.remaining(
      until: sameDay, now: now, seconds: .show, locale: locale, calendar: calendar)
    #expect(short.contains("11:31") && !short.contains("2026"))
    #expect(precise.contains("11:31:00"))
    let future = CountdownFormat.endTime.remaining(
      until: tomorrow, now: now, seconds: .automatic, locale: locale, calendar: calendar)
    #expect(future.contains("26") && future.contains("12:30"))
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
    let shifted = CountdownFormat.endTime.remaining(
      until: sameDay, now: now, seconds: .hide, locale: locale, calendar: calendar)
    #expect(shifted.contains("12:31") && shifted != short)
  }

  @Test func endTimeAndSecondsPersistAndKeepInfiniteHiddenAndIdleStates() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.settings.countdown = true
    model.settings.countdownFormat = .endTime
    model.settings.countdownSeconds = .show
    let restored = try JSONDecoder().decode(
      AppSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    #expect(restored.countdownFormat == .endTime && restored.countdownSeconds == .show)
    model.start(duration: 60)
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    let button = try #require(controller.statusItem.button)
    #expect(button.attributedTitle.string.contains(":"))
    model.start()
    controller.refresh()
    #expect(button.attributedTitle.string == " ∞")
    model.settings.countdown = false
    controller.refresh()
    #expect(button.attributedTitle.string.isEmpty)
    model.settings.countdown = true
    model.stopAll()
    controller.refresh()
    #expect(button.attributedTitle.string.isEmpty && model.engine.automationPaused)
  }
}
