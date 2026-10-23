import Foundation

public struct StateStore: Sendable {
  public let directory: URL
  public var file: URL { directory.appendingPathComponent("holds.json") }
  public init(directory: URL) { self.directory = directory }

  public func load() throws -> EngineSnapshot {
    guard FileManager.default.fileExists(atPath: file.path) else { return EngineSnapshot() }
    return try JSONDecoder().decode(EngineSnapshot.self, from: Data(contentsOf: file))
  }

  public func save(_ snapshot: EngineSnapshot) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

public enum TimeInput {
  public static func duration(_ text: String) throws -> TimeInterval {
    guard text.range(of: #"^\d+(\.\d+)?[smh]$"#, options: .regularExpression) != nil,
      let amount = Double(text.dropLast())
    else { throw WakeError.invalidDuration }
    let seconds = amount * (text.last == "h" ? 3600 : text.last == "m" ? 60 : 1)
    guard seconds.isFinite && seconds > 0 && seconds <= 315_576_000 else {
      throw WakeError.invalidDuration
    }
    return seconds
  }

  public static func until(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws
    -> Date
  {
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count == 2, pieces[0].count <= 2, pieces[1].count == 2,
      let hour = Int(pieces[0]), let minute = Int(pieces[1]),
      (0...23).contains(hour), (0...59).contains(minute),
      let next = calendar.nextDate(
        after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
        matchingPolicy: .nextTime)
    else { throw WakeError.invalidDuration }
    return next
  }
}
