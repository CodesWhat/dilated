import Foundation
import Testing

@testable import DilatedCore

struct ThroughputTests {
  @Test func ratesUseElapsedTimeAnd64BitCounterDifferences() {
    var sampler = ThroughputSampler()
    let base = UInt64(1) << 50
    #expect(sampler.sample(["en0": .init(readBytes: base, writtenBytes: base)], at: 10) == nil)
    #expect(
      sampler.sample(["en0": .init(readBytes: base + 15_000, writtenBytes: base + 5_000)], at: 15)
        == 4_000)
    #expect(
      sampler.sample(["en0": .init(readBytes: base + 15_000, writtenBytes: base + 5_000)], at: 20)
        == 0)
  }

  @Test func unavailableResetAndInterfaceChurnRequireFreshBaselines() {
    var sampler = ThroughputSampler()
    #expect(sampler.sample(["old": .init(readBytes: 100, writtenBytes: 200)], at: 0) == nil)
    #expect(sampler.sample(["new": .init(readBytes: 50_000, writtenBytes: 50_000)], at: 5) == nil)
    #expect(sampler.sample(["new": .init(readBytes: 10, writtenBytes: 20)], at: 10) == nil)
    #expect(sampler.sample(["new": .init(readBytes: 510, writtenBytes: 520)], at: 15) == 200)
    #expect(sampler.sample(nil, at: 20) == nil)
    #expect(sampler.sample(["new": .init(readBytes: 1_000, writtenBytes: 1_000)], at: 25) == nil)
    #expect(sampler.sample(["new": .init(readBytes: 2_000, writtenBytes: 2_000)], at: 25) == nil)
    #expect(sampler.sample([:], at: .nan) == nil)
  }

  @Test func sumsStableDevicesWithoutOverflowOrNewDeviceSpikes() {
    var sampler = ThroughputSampler()
    _ = sampler.sample(
      ["a": .init(readBytes: 0, writtenBytes: 0), "b": .init(readBytes: 0, writtenBytes: 0)], at: 0)
    let counters: [String: ThroughputCounters] = [
      "a": .init(readBytes: 5_000, writtenBytes: 5_000),
      "b": .init(readBytes: 10_000, writtenBytes: 0),
      "c": .init(readBytes: .max, writtenBytes: .max),
    ]
    #expect(sampler.sample(counters, at: 5) == 4_000)
    #expect(sampler.sample(counters, at: 10) == 0)
  }

  @Test func emptyInterfacesHaveKnownZeroOnlyAfterBaseline() {
    var sampler = ThroughputSampler()
    #expect(sampler.sample([:], at: 0) == nil)
    #expect(sampler.sample([:], at: 5) == 0)
  }

  @Test func networkThresholdsFailClosedAndRoundTripAlongsideLegacyRules() throws {
    let now = Date()
    let above = TriggerRule(
      name: "Transfer", criteria: [.networkThroughput(kilobytesPerSecond: 100, atLeast: true)])
    let below = TriggerRule(
      name: "Idle network", criteria: [.networkThroughput(kilobytesPerSecond: 100, atLeast: false)])
    var input = TriggerInputs()
    #expect(!above.matches(input, now: now) && !below.matches(input, now: now))
    input.networkBytesPerSecond = 100_000
    #expect(above.matches(input, now: now) && below.matches(input, now: now))
    input.networkBytesPerSecond = 99_999
    #expect(!above.matches(input, now: now) && below.matches(input, now: now))
    for invalid in [-1.0, .infinity, .nan] {
      input.networkBytesPerSecond = invalid
      #expect(!above.matches(input, now: now) && !below.matches(input, now: now))
    }
    #expect(!TriggerCriterion.networkThroughput(kilobytesPerSecond: -1, atLeast: true).isValid)
    #expect(
      !TriggerCriterion.networkThroughput(kilobytesPerSecond: 10_000_001, atLeast: true).isValid)
    let legacy = Data(
      """
      [{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy CPU","enabled":true,"criteria":[{"cpu":{"percent":20,"atLeast":true}}],"displayAwake":false,"lowPowerOverride":false,"dwellSeconds":30,"graceSeconds":10}]
      """.utf8)
    let decoded = try JSONDecoder().decode([TriggerRule].self, from: legacy)
    #expect(decoded.first?.criteria == [.cpu(percent: 20, atLeast: true)])
    let rules = decoded + [above, below]
    #expect(
      try JSONDecoder().decode([TriggerRule].self, from: JSONEncoder().encode(rules)) == rules)
  }

  @Test func burstSustainedAndIdleReadingsUseDwellGraceAndRespectStop() {
    let now = Date()
    var rule = TriggerRule(
      name: "Backup", criteria: [.networkThroughput(kilobytesPerSecond: 10, atLeast: true)])
    rule.dwellSeconds = 10
    rule.graceSeconds = 5
    var engine = WakeEngine(now: now)
    var evaluator = TriggerEvaluator()
    var input = TriggerInputs()
    func reconcile(_ uptime: TimeInterval, _ rate: Double) {
      input.networkBytesPerSecond = rate
      evaluator.reconcile(
        rules: [rule], inputs: input, engine: &engine, now: now.addingTimeInterval(uptime),
        uptime: uptime)
    }
    reconcile(0, 20_000)
    reconcile(5, 0)
    #expect(engine.holds.isEmpty)
    reconcile(10, 20_000)
    reconcile(20, 20_000)
    #expect(engine.holds.count == 1)
    reconcile(25, 0)
    #expect(engine.holds.count == 1)
    reconcile(30, 0)
    #expect(engine.holds.isEmpty)
    engine.stopAll()
    reconcile(35, 20_000)
    reconcile(60, 20_000)
    #expect(engine.holds.isEmpty && engine.automationPaused)
  }
}
