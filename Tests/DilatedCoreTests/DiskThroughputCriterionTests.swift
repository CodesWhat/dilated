import Foundation
import Testing

@testable import DilatedCore

struct DiskThroughputCriterionTests {
  @Test func diskThresholdRequiresKnownInputAndKeepsNetworkSettingsCompatible() throws {
    let now = Date()
    let above = TriggerRule(
      name: "Disk busy", criteria: [.diskThroughput(kilobytesPerSecond: 1_000, atLeast: true)])
    let below = TriggerRule(
      name: "Disk idle", criteria: [.diskThroughput(kilobytesPerSecond: 1_000, atLeast: false)])
    var input = TriggerInputs()
    #expect(!above.matches(input, now: now) && !below.matches(input, now: now))
    input.diskBytesPerSecond = 1_000_000
    #expect(above.matches(input, now: now) && below.matches(input, now: now))
    input.diskBytesPerSecond = 999_999
    #expect(!above.matches(input, now: now) && below.matches(input, now: now))
    for invalid in [-1.0, .nan, .infinity] {
      input.diskBytesPerSecond = invalid
      #expect(!above.matches(input, now: now) && !below.matches(input, now: now))
    }
    #expect(!TriggerCriterion.diskThroughput(kilobytesPerSecond: -1, atLeast: false).isValid)
    #expect(
      !TriggerCriterion.diskThroughput(kilobytesPerSecond: 10_000_001, atLeast: false).isValid)
    let prior = Data(#"{"networkThroughput":{"kilobytesPerSecond":100,"atLeast":true}}"#.utf8)
    #expect(
      try JSONDecoder().decode(TriggerCriterion.self, from: prior)
        == .networkThroughput(kilobytesPerSecond: 100, atLeast: true))
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(above)) == above)
  }

  @Test func sampledDiskBurstSustainedAndIdleSequencesRespectStop() {
    let start = Date()
    var rule = TriggerRule(
      name: "Backup", criteria: [.diskThroughput(kilobytesPerSecond: 10, atLeast: true)])
    rule.dwellSeconds = 10
    rule.graceSeconds = 5
    var sampler = ThroughputSampler()
    var input = TriggerInputs()
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    var bytes: UInt64 = 0
    func sample(_ seconds: TimeInterval, _ additional: UInt64) {
      bytes += additional
      input.diskBytesPerSecond = sampler.sample(
        ["disk": .init(readBytes: bytes, writtenBytes: 0)], at: seconds)
      evaluator.reconcile(
        rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(seconds),
        uptime: seconds)
    }
    sample(0, 0)
    sample(5, 100_000)
    sample(10, 0)
    #expect(engine.holds.isEmpty)
    sample(15, 100_000)
    sample(20, 100_000)
    sample(25, 100_000)
    #expect(engine.holds.count == 1)
    sample(30, 0)
    #expect(engine.holds.count == 1)
    sample(35, 0)
    #expect(engine.holds.isEmpty)
    engine.stopAll()
    sample(40, 100_000)
    sample(50, 200_000)
    #expect(engine.holds.isEmpty && engine.automationPaused)
  }
}
