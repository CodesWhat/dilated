import Foundation

public enum CountdownFormat: String, Codable, CaseIterable, Sendable {
  case compact, clock

  var label: String {
    switch self {
    case .compact: "Compact · 1h 30m"
    case .clock: "Clock · 1:30:00"
    }
  }

  @MainActor func remaining(until date: Date, now: Date) -> String {
    if self == .compact { return AppModel.remaining(until: date, now: now) }
    let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
    return seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
