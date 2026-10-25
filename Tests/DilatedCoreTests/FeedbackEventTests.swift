import Foundation
import Testing

@testable import DilatedCore

struct FeedbackEventTests {
  @Test func explicitExtensionIsDifferentFromRenewalAndKeepsOneHistorySegment() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var engine = WakeEngine()
    let manual = try engine.start(source: .manual, label: "Timer", duration: 60, now: now)
    let lease = try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    var history = SessionHistory()
    history.receive(engine.takeHistoryEvents(), now: now)
    try engine.renew(id: lease.id, duration: 120, now: now.addingTimeInterval(1))
    #expect(engine.takeHistoryEvents().isEmpty)
    try engine.extend(id: manual.id, by: 30, now: now.addingTimeInterval(2))
    let events = engine.takeHistoryEvents()
    #expect(events.count == 1)
    #expect(events.first?.kind == .extended && events.first?.hold.id == manual.id)
    history.receive(events, now: now.addingTimeInterval(2))
    #expect(history.active.count == 2 && history.records.isEmpty)
    engine.stop(id: manual.id, now: now.addingTimeInterval(3))
    #expect(engine.takeHistoryEvents().first?.kind == .ended)
  }
}
