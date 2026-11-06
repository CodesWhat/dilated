import DilatedCore
import Foundation
import Testing

struct LeavingModeTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func waitsForTheLastHoldThenRequestsSleepExactlyOnceAfterGrace() throws {
    var engine = WakeEngine()
    _ = try engine.start(source: .cli, label: "Build", duration: 10, now: now)
    _ = try engine.start(source: .lease, label: "Agent", duration: 20, now: now)
    engine.leaveWhenIdle()
    let whileBothRun = !engine.leavingSleepReady(now: now)
    #expect(whileBothRun)
    engine.tick(now: now.addingTimeInterval(10))
    let afterFirstEnds = !engine.leavingSleepReady(now: now.addingTimeInterval(10))
    #expect(afterFirstEnds)
    engine.tick(now: now.addingTimeInterval(20))
    let graceBegins = !engine.leavingSleepReady(now: now.addingTimeInterval(20))
    #expect(graceBegins)
    let duringGrace = !engine.leavingSleepReady(now: now.addingTimeInterval(24))
    #expect(duringGrace)
    let afterGrace = engine.leavingSleepReady(now: now.addingTimeInterval(25))
    #expect(afterGrace)
    let firstRequest = engine.takeLeavingSleepRequest(now: now.addingTimeInterval(25))
    #expect(firstRequest)
    #expect(!engine.leavingPending)
    let secondRequest = !engine.takeLeavingSleepRequest(now: now.addingTimeInterval(100))
    #expect(secondRequest)
  }

  @Test func aNewHoldDuringGraceCancelsTheOneShotButRenewingExistingWorkDoesNot() throws {
    var engine = WakeEngine()
    let hold = try engine.start(source: .lease, label: "Agent", duration: 10, now: now)
    engine.leaveWhenIdle()
    try engine.renew(id: hold.id, duration: 15, now: now.addingTimeInterval(5))
    #expect(engine.leavingPending)
    engine.tick(now: now.addingTimeInterval(20))
    let renewedGrace = !engine.leavingSleepReady(now: now.addingTimeInterval(20))
    #expect(renewedGrace)
    _ = try engine.start(source: .manual, label: "New work", now: now.addingTimeInterval(22))
    #expect(!engine.leavingPending)
    engine.stopAll(now: now.addingTimeInterval(23))
    let afterStop = !engine.takeLeavingSleepRequest(now: now.addingTimeInterval(100))
    #expect(afterStop)
  }

  @Test func cancelStopQuitAndRelaunchNeverKeepALeavingRequest() {
    var engine = WakeEngine()
    engine.leaveWhenIdle()
    engine.cancelLeaving()
    #expect(!engine.leavingPending)
    engine.leaveWhenIdle()
    engine.stopAll(now: now)
    #expect(!engine.leavingPending)
    engine.leaveWhenIdle()
    #expect(!WakeEngine(snapshot: engine.snapshot, now: now).leavingPending)
    engine.quit(now: now)
    #expect(!engine.leavingPending)
  }

  @Test func rejectedStartsDoNotCancelLeavingButRestoredNewHoldsDo() throws {
    var engine = WakeEngine()
    engine.leaveWhenIdle()
    #expect(throws: WakeError.self) {
      try engine.start(source: .cli, label: "Bad", duration: -1, now: now)
    }
    #expect(engine.leavingPending)
    var other = WakeEngine()
    let hold = try other.start(source: .manual, label: "Restored", duration: 60, now: now)
    engine.restore(holds: [hold], now: now)
    #expect(!engine.leavingPending)
  }
}
