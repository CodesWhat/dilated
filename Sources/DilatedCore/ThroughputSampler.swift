import Foundation

public struct ThroughputCounters: Equatable, Sendable {
  public var readBytes: UInt64
  public var writtenBytes: UInt64
  public init(readBytes: UInt64, writtenBytes: UInt64) {
    self.readBytes = readBytes
    self.writtenBytes = writtenBytes
  }
}

public struct ThroughputSampler: Sendable {
  private var previous: (at: TimeInterval, counters: [String: ThroughputCounters])?
  public init() {}

  public mutating func sample(
    _ counters: [String: ThroughputCounters]?, at uptime: TimeInterval
  ) -> Double? {
    guard let counters, uptime.isFinite else {
      previous = nil
      return nil
    }
    defer { previous = (uptime, counters) }
    guard let previous, uptime > previous.at else { return nil }
    if counters.isEmpty && previous.counters.isEmpty { return 0 }
    var bytes: Double = 0
    var comparable = false
    for (identity, current) in counters {
      guard let old = previous.counters[identity], current.readBytes >= old.readBytes,
        current.writtenBytes >= old.writtenBytes
      else { continue }
      comparable = true
      bytes +=
        Double(current.readBytes - old.readBytes) + Double(current.writtenBytes - old.writtenBytes)
    }
    guard comparable else { return nil }
    let rate = bytes / (uptime - previous.at)
    return rate.isFinite ? rate : nil
  }
}
