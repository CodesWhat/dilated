import Foundation
import Testing

@testable import DilatedCore

struct HistoryTests {
  private let origin = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func enginePreservesTheActualEndCauseForEachHold() throws {
    var engine = WakeEngine()
    let first = try engine.start(source: .manual, label: "Timer", duration: 10, now: origin)
    engine.tick(now: origin.addingTimeInterval(12))
    let second = try engine.start(source: .cli, label: "Build", now: origin.addingTimeInterval(12))
    engine.updatePower(.init(lowPowerMode: true), now: origin.addingTimeInterval(15))
    let events = engine.takeHistoryEvents()
    #expect(events.count == 4)
    #expect(events[1].hold.id == first.id && events[1].endReason == .expired)
    #expect(events[1].at == origin.addingTimeInterval(10))
    #expect(events[3].hold.id == second.id && events[3].endReason == .lowPowerMode)
    #expect(engine.takeHistoryEvents().isEmpty)
  }

  @Test func overlappingHoldsCountTheirUnionOnce() throws {
    var engine = WakeEngine()
    var history = SessionHistory()
    let first = try engine.start(source: .manual, label: "A", now: origin)
    history.receive(engine.takeHistoryEvents(), now: origin)
    let second = try engine.start(source: .cli, label: "B", now: origin.addingTimeInterval(10))
    history.receive(engine.takeHistoryEvents(), now: origin.addingTimeInterval(10))
    engine.stop(id: first.id, now: origin.addingTimeInterval(20))
    history.receive(engine.takeHistoryEvents(), now: origin.addingTimeInterval(20))
    engine.stop(id: second.id, now: origin.addingTimeInterval(30))
    history.receive(engine.takeHistoryEvents(), now: origin.addingTimeInterval(30))
    #expect(history.records.count == 2)
    #expect(history.statistics(now: origin.addingTimeInterval(40)).awakeSeconds == 30)
    #expect(history.records.reduce(0) { $0 + $1.duration } == 40)
    #expect(history.records.allSatisfy { $0.endReason == .stopped })
  }

  @Test func interruptedHistoryEndsAtTheLastCheckpointAndRestorationStartsANewSegment() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(directory: directory)
    var engine = WakeEngine()
    var history = SessionHistory()
    let hold = try engine.start(source: .manual, label: "Timer", duration: 120, now: origin)
    history.receive(engine.takeHistoryEvents(), now: origin)
    history.checkpoint(at: origin.addingTimeInterval(20))
    try store.save(history, now: origin.addingTimeInterval(20))
    var loaded = try store.load(now: origin.addingTimeInterval(100))
    #expect(loaded.active.isEmpty)
    #expect(loaded.records.count == 1)
    #expect(loaded.records[0].endReason == .interrupted)
    #expect(loaded.records[0].duration == 20)
    var restored = WakeEngine(snapshot: engine.snapshot, now: origin.addingTimeInterval(100))
    loaded.receive(restored.takeHistoryEvents(), now: origin.addingTimeInterval(100))
    #expect(loaded.active.count == 1)
    #expect(loaded.active[0].holdID == hold.id)
    #expect(loaded.active[0].startedAt == origin.addingTimeInterval(100))
    #expect(loaded.statistics(now: origin.addingTimeInterval(110)).awakeSeconds == 30)
  }

  @Test func retentionAndFileSizeStayBoundedWithoutTruncatingJson() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(directory: directory, maximumRecords: 3, maximumBytes: 1600)
    var engine = WakeEngine()
    var history = SessionHistory()
    for index in 0..<12 {
      let now = origin.addingTimeInterval(Double(index * 10))
      try engine.start(source: .manual, label: String(repeating: "a", count: 200), now: now)
      engine.stopAll(now: now.addingTimeInterval(5))
      history.receive(engine.takeHistoryEvents(), now: now.addingTimeInterval(5))
    }
    try store.save(history, now: origin.addingTimeInterval(200))
    let file = directory.appendingPathComponent("history.jsonl")
    #expect(try Data(contentsOf: file).count <= 1600)
    let loaded = try store.load(now: origin.addingTimeInterval(200))
    #expect(loaded.records.count <= 3 && !loaded.records.isEmpty)
    #expect(loaded.records.last?.label == String(repeating: "a", count: 200))
    #expect(
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        == 0o600)
    let expired = try store.load(now: origin.addingTimeInterval(31 * 86400))
    #expect(expired.records.isEmpty)
  }

  @Test func activeCheckpointsStayBoundedDuringUnusualConcurrentUse() throws {
    var engine = WakeEngine()
    var history = SessionHistory()
    for index in 0..<1030 {
      try engine.start(source: .manual, label: "Reason \(index)", now: origin)
      history.receive(engine.takeHistoryEvents(), now: origin)
    }
    #expect(history.active.count == 1024)
    #expect(engine.holds.count == 1030)
  }

  @Test func completedFileCannotContainAnUnfinishedRecord() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var engine = WakeEngine()
    var history = SessionHistory()
    try engine.start(source: .manual, label: "A", now: origin)
    history.receive(engine.takeHistoryEvents(), now: origin)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var data = try JSONEncoder().encode(history.active[0])
    data.append(10)
    try data.write(to: directory.appendingPathComponent("history.jsonl"))
    #expect(throws: (any Error).self) { try HistoryStore(directory: directory).load(now: origin) }
  }

  @Test func exportIncludesReasonsAndClearDoesNotFabricateNewStarts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(directory: directory)
    var engine = WakeEngine()
    var history = SessionHistory()
    let hold = try engine.start(source: .trigger, label: "Editor", now: origin)
    history.receive(engine.takeHistoryEvents(), now: origin)
    history.clear(at: origin.addingTimeInterval(10))
    #expect(history.records.isEmpty)
    #expect(history.statistics(now: origin.addingTimeInterval(12)).awakeSeconds == 2)
    engine.stop(id: hold.id, reason: .conditionEnded, now: origin.addingTimeInterval(20))
    history.receive(engine.takeHistoryEvents(), now: origin.addingTimeInterval(20))
    let data = try store.export(history, now: origin.addingTimeInterval(20))
    let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(document?["scope"] as? String == "App-managed awake reasons")
    #expect(String(decoding: data, as: UTF8.self).contains("conditionEnded"))
    #expect(history.records[0].duration == 10)
  }
}
