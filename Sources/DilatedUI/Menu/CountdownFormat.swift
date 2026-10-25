import Foundation

public enum CountdownSeconds: String, Codable, CaseIterable, Sendable {
  case automatic, show, hide
  var label: String {
    switch self {
    case .automatic: "Format default"
    case .show: "Show"
    case .hide: "Hide"
    }
  }
}

public enum CountdownFormat: String, Codable, CaseIterable, Sendable {
  case compact, clock, endTime

  var label: String { label(seconds: .automatic) }
  func label(seconds: CountdownSeconds) -> String {
    switch self {
    case .compact: seconds == .show ? "Compact · 1h 30m 0s" : "Compact · 1h 30m"
    case .clock: seconds == .hide ? "Clock · 1:30" : "Clock · 1:30:00"
    case .endTime: "End time"
    }
  }

  @MainActor func remaining(
    until date: Date, now: Date, seconds: CountdownSeconds = .automatic,
    locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    if self == .endTime {
      let style = Date.FormatStyle(
        date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated,
        time: seconds == .show ? .standard : .shortened,
        locale: locale, calendar: calendar, timeZone: calendar.timeZone)
      return date.formatted(style)
    }
    if self == .compact && seconds == .automatic {
      return AppModel.remaining(until: date, now: now)
    }
    let total = max(0, Int(ceil(date.timeIntervalSince(now))))
    if seconds == .hide {
      let minutes = (total + 59) / 60
      if self == .clock { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
      return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    if self == .compact {
      return total >= 3600
        ? "\(total / 3600)h \((total % 3600) / 60)m \(total % 60)s"
        : total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
    return total >= 3600
      ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
      : String(format: "%d:%02d", total / 60, total % 60)
  }
}
