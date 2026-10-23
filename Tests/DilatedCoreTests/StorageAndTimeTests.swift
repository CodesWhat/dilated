import Foundation
import Testing

@testable import DilatedCore

struct StorageAndTimeTests {
  @Test func persistsPauseAndTimerDeadlines() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(directory: directory)
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Timer", duration: 60)
    try store.save(engine.snapshot)
    #expect(try store.load().holds == engine.holds)
    engine.stopAll()
    try store.save(engine.snapshot)
    #expect(try store.load().automationPaused)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }
  @Test func missingStateIsEmptyButCorruptStateIsReported() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(directory: directory)
    #expect(try store.load().holds.isEmpty)
    try store.save(EngineSnapshot())
    try Data("broken".utf8).write(to: store.file)
    #expect(throws: (any Error).self) { try store.load() }
  }
  @Test func durationsAndUntilTimesAreStrict() throws {
    #expect(try TimeInput.duration("90m") == 5400)
    #expect(try TimeInput.duration("1.5h") == 5400)
    #expect(try TimeInput.duration("30s") == 30)
    for bad in ["0m", "-1h", "nan", "1h junk", "1", "2d"] {
      #expect(throws: (any Error).self) { try TimeInput.duration(bad) }
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let until = try TimeInput.until("07:00", now: now, calendar: calendar)
    #expect(until > now)
    #expect(calendar.component(.hour, from: until) == 7)
    #expect(until.timeIntervalSince(now) <= 86400)
    for bad in ["24:00", "12:60", "garbage", "1:2:3"] {
      #expect(throws: (any Error).self) { try TimeInput.until(bad, now: now, calendar: calendar) }
    }
  }
}
