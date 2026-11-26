import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

@MainActor private final class FakeAssertions: AssertionControlling {
  var held: [Hold] = []
  var releases = 0
  var failSynchronize = false
  var activeTypes: Set<String> { held.isEmpty ? [] : ["PreventUserIdleSystemSleep"] }
  func synchronize(holds: [Hold], now: Date) throws {
    if failSynchronize { throw InputError("boom") }
    held = holds
  }
  func releaseAll() {
    held = []
    releases += 1
  }
}

@MainActor private final class Rig {
  var clock = Date(timeIntervalSince1970: 1_000_000)
  var power = PowerState()
  var sent: [ControlRequest] = []
  var replies: [Result<ControlResponse, any Error>] = []
  var snapshot: Result<EngineSnapshot, any Error> = .success(EngineSnapshot())
  var reports: [String] = []
  let assertions = FakeAssertions()
  let keepAwake: RunKeepAwake
  let managedID = UUID()

  init(floor: Int? = nil, closedLid: Bool = false) throws {
    var local = WakeEngine(power: PowerState(), batteryFloor: floor)
    // Mirrors `dilated run`: an indefinite, local-only hold.
    _ = try local.start(source: .manual, label: "build", duration: nil, now: Date())
    let box = Box()
    keepAwake = RunKeepAwake(
      local: local, managedID: managedID, label: "build", displayAwake: false,
      lowPowerOverride: false, closedLid: closedLid, assertions: assertions,
      environment: .init(
        now: { box.rig?.clock ?? Date() }, readPower: { box.rig?.power ?? PowerState() },
        send: { request in
          let rig = box.rig!
          rig.sent.append(request)
          guard !rig.replies.isEmpty else { return ControlResponse(ok: true, id: rig.managedID) }
          return try rig.replies.removeFirst().get()
        },
        loadSnapshot: { try box.rig!.snapshot.get() }, report: { box.rig?.reports.append($0) }))
    box.rig = self
    try assertions.synchronize(holds: local.holds, now: clock)
  }
  final class Box: @unchecked Sendable { weak var rig: Rig? }
}

@MainActor struct RunKeepAwakeTests {
  @Test func aGapLongerThanTheLeaseKeepsTheLocalAssertion() throws {
    let rig = try Rig()
    rig.clock.addTimeInterval(600)
    rig.keepAwake.refresh()
    #expect(rig.keepAwake.keepingAwake)
    #expect(rig.assertions.held.count == 1)
    #expect(rig.assertions.releases == 0)
    #expect(rig.reports.isEmpty)
    #expect(rig.sent.first?.action == .renew)
  }

  @Test func anExpiredAppLeaseIsRegisteredAgainAfterTheGap() throws {
    let rig = try Rig()
    let fresh = UUID()
    rig.replies = [
      .success(ControlResponse(ok: false, message: "That hold has ended.")),
      .success(ControlResponse(ok: true, id: fresh)),
    ]
    rig.clock.addTimeInterval(120)
    rig.keepAwake.refresh()
    #expect(rig.keepAwake.keepingAwake)
    #expect(rig.keepAwake.managedID == fresh)
    #expect(rig.sent.map(\.action) == [.renew, .runner])
    #expect(rig.reports.isEmpty)
  }

  @Test func aReleasedHoldIsNotRegisteredAgain() throws {
    let rig = try Rig()
    rig.replies = [
      .success(ControlResponse(ok: false, message: "That hold has ended.", released: true))
    ]
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.sent.map(\.action) == [.renew])
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
    #expect(rig.reports[0].contains("released"))
  }

  @Test func reRegisteringKeepsTheClosedLidRequest() throws {
    let rig = try Rig(closedLid: true)
    rig.replies = [.success(ControlResponse(ok: false, message: "gone"))]
    rig.keepAwake.refresh()
    #expect(rig.sent.map(\.action) == [.renew, .runner])
    #expect(rig.sent[1].closedLid)
    let plain = try Rig()
    plain.replies = [.success(ControlResponse(ok: false, message: "gone"))]
    plain.keepAwake.refresh()
    #expect(!plain.sent[1].closedLid)
  }

  @Test func aStoppedRunIsReportedAndReleasedWithoutThrowing() throws {
    let rig = try Rig()
    rig.replies = [
      .success(ControlResponse(ok: false, message: "That hold has ended.")),
      .success(ControlResponse(ok: false, message: "Automation is paused.")),
    ]
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
    #expect(rig.reports[0].contains("Automation is paused."))
    #expect(rig.reports[0].contains("still running"))
    rig.keepAwake.refresh()
    #expect(rig.sent.count == 2)
    #expect(rig.reports.count == 1)
  }

  @Test func aPersistedStopEndsKeepAwakeWhenTheAppIsUnreachable() throws {
    let rig = try Rig()
    rig.replies = [.failure(AppConnectionUnavailable(text: "down"))]
    rig.snapshot = .success(EngineSnapshot(automationPaused: true))
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
  }

  @Test func aPersistedSingleHoldReleaseEndsKeepAwakeWhenTheAppIsUnreachable() throws {
    let rig = try Rig()
    rig.replies = [.failure(AppConnectionUnavailable(text: "down"))]
    rig.snapshot = .success(
      EngineSnapshot(released: [ReleasedHold(id: rig.managedID, at: rig.clock)]))
    rig.clock.addTimeInterval(60)
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
  }

  @Test func anOldOrUnrelatedPersistedReleaseKeepsTheLocalHold() throws {
    let rig = try Rig()
    rig.replies = [.failure(AppConnectionUnavailable(text: "down"))]
    rig.snapshot = .success(
      EngineSnapshot(released: [
        ReleasedHold(id: UUID(), at: rig.clock),
        ReleasedHold(
          id: rig.managedID, at: rig.clock.addingTimeInterval(-WakeEngine.releasedMaxAge - 1)),
      ]))
    rig.keepAwake.refresh()
    #expect(rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 0)
  }

  @Test func anUnreachableAppWithoutAStopKeepsTheLocalHold() throws {
    let rig = try Rig()
    rig.replies = [.failure(AppConnectionUnavailable(text: "down"))]
    rig.clock.addTimeInterval(300)
    rig.keepAwake.refresh()
    #expect(rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 0)
    #expect(rig.reports.isEmpty)
  }

  @Test func anUnreadableStateFileIsReportedNotThrown() throws {
    let rig = try Rig()
    rig.replies = [.failure(AppConnectionUnavailable(text: "down"))]
    rig.snapshot = .failure(InputError("corrupt"))
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.reports.count == 1)
    #expect(rig.reports[0].contains("corrupt"))
  }

  @Test func aRefreshFailureIsReportedAndReleased() throws {
    let rig = try Rig()
    rig.assertions.failSynchronize = true
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
    #expect(rig.reports[0].contains("boom"))
  }

  @Test func lowPowerModeStillReleasesAndSaysWhy() throws {
    let rig = try Rig()
    rig.power = PowerState(lowPowerMode: true)
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports.count == 1)
    #expect(rig.sent.isEmpty)
  }

  @Test func theBatteryFloorStillReleases() throws {
    let rig = try Rig(floor: 20)
    rig.power = PowerState(onBattery: true, batteryPercent: 10)
    rig.keepAwake.refresh()
    #expect(!rig.keepAwake.keepingAwake)
    #expect(rig.assertions.releases == 1)
    #expect(rig.reports[0].contains("battery"))
  }
}
