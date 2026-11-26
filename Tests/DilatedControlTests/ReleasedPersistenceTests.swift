import DilatedCore
import Foundation
import Testing

struct ReleasedPersistenceTests {
  private func release(_ engine: inout WakeEngine, at now: Date) throws -> UUID {
    let hold = try engine.start(source: .runner, label: "r", duration: 600, now: now)
    engine.stop(id: hold.id, now: now)
    return hold.id
  }

  @Test func releasedIDsSurviveARestart() throws {
    let now = Date()
    var engine = WakeEngine(now: now)
    let id = try release(&engine, at: now)
    let data = try JSONEncoder().encode(engine.snapshot)
    let restored = WakeEngine(
      snapshot: try JSONDecoder().decode(EngineSnapshot.self, from: data), now: now)
    #expect(restored.wasReleased(id: id, now: now))
    #expect(!restored.wasReleased(id: UUID(), now: now))
  }

  @Test func theListKeepsOnlyTheNewest64() throws {
    let now = Date()
    var engine = WakeEngine(now: now)
    var ids: [UUID] = []
    for _ in 0..<70 { ids.append(try release(&engine, at: now)) }
    #expect(engine.snapshot.released.count == 64)
    #expect(!engine.wasReleased(id: ids[5], now: now))
    #expect(engine.wasReleased(id: ids[6], now: now))
    #expect(engine.wasReleased(id: ids[69], now: now))
  }

  @Test func entriesExpireAfterADay() throws {
    let now = Date()
    var engine = WakeEngine(now: now)
    let id = try release(&engine, at: now)
    let later = now.addingTimeInterval(24 * 3600 + 1)
    #expect(!engine.wasReleased(id: id, now: later))
    let restored = WakeEngine(snapshot: engine.snapshot, now: later)
    #expect(restored.snapshot.released.isEmpty)
  }

  @Test func oldSnapshotsWithoutTheKeyStillDecode() throws {
    let json = Data(#"{"holds":[],"automationPaused":false}"#.utf8)
    let snap = try JSONDecoder().decode(EngineSnapshot.self, from: json)
    #expect(snap.released.isEmpty)
    let out = try JSONEncoder().encode(snap)
    #expect(!String(decoding: out, as: UTF8.self).contains("released"))
  }
}
