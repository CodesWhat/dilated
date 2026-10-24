import Foundation

public struct CPUUsageSampler: Sendable {
  private var previous: [UInt32]?
  public init() {}
  public mutating func sample(_ ticks: [UInt32]?) -> Double? {
    guard let ticks, ticks.count == 4 else {
      previous = nil
      return nil
    }
    defer { previous = ticks }
    guard let previous else { return nil }
    let deltas = zip(ticks, previous).map { UInt64($0 &- $1) }
    let total = deltas.reduce(0, +)
    guard total > 0 else { return nil }
    return Double(total - deltas[2]) * 100 / Double(total)
  }
}
