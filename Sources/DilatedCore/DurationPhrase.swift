import Foundation

/// Parses short English phrases such as "for 90m", "2h30", "until 5pm" or "until tomorrow 9am" into either a
/// duration or an absolute deadline. Pure: no UI, no CLI, no clock reads. Ambiguous input is rejected, never guessed.
public enum DurationPhrase {
  /// Longest phrase-entered session. Tighter than the engine's own ceiling on purpose: a typed phrase that reaches
  /// past a week is far more likely a typo than intent.
  public static let maximumSeconds: TimeInterval = 7 * 86400

  public enum Result: Equatable, Sendable {
    case duration(TimeInterval)
    case deadline(Date)
    case rejected(Rejection)
  }

  public enum Rejection: Error, Equatable, Sendable {
    case empty
    /// Not a duration or deadline shape at all.
    case unrecognized
    /// A number with no unit, such as "5" or "for 90".
    case missingUnit
    case unknownUnit(String)
    /// A clock time that could be read two ways, such as "until 5" or, on a 12-hour clock, "until 5:30".
    case ambiguousClock
    /// An impossible clock time, such as "13pm" or "25:00".
    case invalidClock
    /// Zero, negative, or an empty total.
    case notPositive
    case tooLong
    /// "until today 9am" when 9am is already behind us.
    case alreadyPassed
  }

  public static func parse(_ text: String, now: Date, calendar: Calendar) -> Result {
    let phrase = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !phrase.isEmpty else { return .rejected(.empty) }
    if phrase == "until" || phrase.hasPrefix("until ") {
      return parseDeadline(
        String(phrase.dropFirst(5)).trimmingCharacters(in: .whitespaces), now: now,
        calendar: calendar)
    }
    let body = phrase.hasPrefix("for ") ? String(phrase.dropFirst(4)) : phrase
    return parseDuration(body)
  }

  // MARK: Durations

  private static let unitTable: [String: (rank: Int, seconds: Double)] = {
    var table: [String: (rank: Int, seconds: Double)] = [:]
    for name in ["h", "hr", "hrs", "hour", "hours"] { table[name] = (0, 3600) }
    for name in ["m", "min", "mins", "minute", "minutes"] { table[name] = (1, 60) }
    for name in ["s", "sec", "secs", "second", "seconds"] { table[name] = (2, 1) }
    return table
  }()

  private static let segment = try! NSRegularExpression(
    pattern: #"^\s*(\d+(?:\.\d+)?)\s*([a-z]*)\s*"#)

  private static func parseDuration(_ body: String) -> Result {
    if body.hasPrefix("-") { return .rejected(.notPositive) }
    // The compact single-unit form shares the CLI's grammar, so "90m" means the same thing in both places.
    if body.range(of: #"^\d+(\.\d+)?[smh]$"#, options: .regularExpression) != nil {
      guard let seconds = try? TimeInput.duration(body) else {
        return .rejected(Double(body.dropLast()) == 0 ? .notPositive : .tooLong)
      }
      return bounded(seconds)
    }

    var remainder = body
    var total = 0.0
    var lastRank = -1
    var count = 0
    while !remainder.isEmpty {
      let whole = NSRange(remainder.startIndex..., in: remainder)
      guard let match = segment.firstMatch(in: remainder, range: whole),
        match.range.length > 0,
        let numberRange = Range(match.range(at: 1), in: remainder),
        let unitRange = Range(match.range(at: 2), in: remainder),
        let amount = Double(remainder[numberRange])
      else { return .rejected(.unrecognized) }
      let unit = String(remainder[unitRange])
      remainder = String(remainder[Range(match.range, in: remainder)!.upperBound...])
      count += 1

      if unit.isEmpty {
        // "2h30" and "1h 15": a trailing bare number is minutes, but only right after hours.
        guard count > 1, lastRank == 0, remainder.isEmpty, amount == amount.rounded(), amount < 60
        else { return .rejected(.missingUnit) }
        total += amount * 60
        break
      }
      guard let entry = unitTable[unit] else { return .rejected(.unknownUnit(unit)) }
      // Descending, no repeats: "1h 15m" yes, "15m 1h" and "1h 1h" no. Fractions only stand alone.
      guard entry.rank > lastRank else { return .rejected(.unrecognized) }
      if amount != amount.rounded(), count > 1 || !remainder.isEmpty {
        return .rejected(.unrecognized)
      }
      lastRank = entry.rank
      total += amount * entry.seconds
    }
    return bounded(total)
  }

  private static func bounded(_ seconds: Double) -> Result {
    guard seconds.isFinite, seconds > 0 else { return .rejected(.notPositive) }
    guard seconds <= maximumSeconds else { return .rejected(.tooLong) }
    return .duration(seconds)
  }

  // MARK: Deadlines

  private enum Day { case today, tomorrow }

  private static func parseDeadline(_ body: String, now: Date, calendar: Calendar) -> Result {
    var words = body.split(separator: " ").map(String.init)
    var day: Day?
    if let first = words.first, let parsed = dayWord(first) {
      day = parsed
      words.removeFirst()
    } else if let last = words.last, let parsed = dayWord(last) {
      day = parsed
      words.removeLast()
    }
    guard !words.isEmpty else { return .rejected(day == nil ? .empty : .unrecognized) }

    let clock: (hour: Int, minute: Int)
    switch parseClock(words.joined(), uses24Hour: uses24HourClock(calendar)) {
    case .success(let value): clock = value
    case .failure(let reason): return .rejected(reason)
    }

    let components = DateComponents(hour: clock.hour, minute: clock.minute, second: 0)
    let found: Date?
    if let day {
      let today = calendar.startOfDay(for: now)
      guard
        let target = day == .today ? today : calendar.date(byAdding: .day, value: 1, to: today),
        let match = calendar.nextDate(
          after: target.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime,
          repeatedTimePolicy: .first, direction: .forward),
        calendar.isDate(match, inSameDayAs: target)
      else { return .rejected(.invalidClock) }
      found = match
    } else {
      // Next occurrence strictly after now, so "until 1am" at 11pm lands on tomorrow.
      found = calendar.nextDate(
        after: now, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
        direction: .forward)
    }
    guard let deadline = found else { return .rejected(.invalidClock) }
    guard deadline > now else { return .rejected(.alreadyPassed) }
    guard deadline.timeIntervalSince(now) <= maximumSeconds else { return .rejected(.tooLong) }
    return .deadline(deadline)
  }

  private static func dayWord(_ word: String) -> Day? {
    switch word {
    case "today": .today
    case "tomorrow": .tomorrow
    default: nil
    }
  }

  /// 24-hour preference from the calendar's locale (en_US when it has none, so tests don't depend on the host).
  static func uses24HourClock(_ calendar: Calendar) -> Bool {
    let locale = calendar.locale ?? Locale(identifier: "en_US")
    let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
    return !format.contains("a")
  }

  private static let clockPattern = try! NSRegularExpression(
    pattern: #"^(\d{1,2})(?::(\d{2}))?(am|pm|a\.m\.|p\.m\.)?$"#)

  private static func parseClock(_ text: String, uses24Hour: Bool)
    -> Swift.Result<(hour: Int, minute: Int), Rejection>
  {
    if text == "noon" { return .success((12, 0)) }
    if text == "midnight" { return .success((0, 0)) }
    guard
      let match = clockPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let hourRange = Range(match.range(at: 1), in: text), let hour = Int(text[hourRange])
    else { return .failure(.unrecognized) }
    let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
    let suffix = Range(match.range(at: 3), in: text).map {
      String(text[$0]).replacingOccurrences(of: ".", with: "")
    }
    if let minute, minute > 59 { return .failure(.invalidClock) }

    if let suffix {
      guard (1...12).contains(hour) else { return .failure(.invalidClock) }
      let base = hour % 12
      return .success((suffix == "pm" ? base + 12 : base, minute ?? 0))
    }
    // No am/pm. A bare hour ("until 5") is always ambiguous; with a colon, 13:00 and 00:30 can only be 24-hour,
    // while "5:30" or "09:00" is a coin flip on a 12-hour clock.
    guard let minute else { return .failure(.ambiguousClock) }
    guard hour <= 23 else { return .failure(.invalidClock) }
    if !uses24Hour && (1...12).contains(hour) { return .failure(.ambiguousClock) }
    return .success((hour, minute))
  }
}
