import Foundation
import Testing

@testable import DilatedCore

struct ClosedLidTests {
  @Test func savedClosedLidIntentSurvivesEncodingButNeverRestartsAutomatically() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Build", duration: 600, now: now)
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.snapshot)) as? [String: Any])
    var holds = try #require(json["holds"] as? [[String: Any]])
    holds[0]["closedLid"] = true
    json["holds"] = holds
    let snapshot = try JSONDecoder().decode(
      EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.holds[0]))
        as? [String: Any])
    #expect(encoded["closedLid"] as? Bool == true)
    let restored = WakeEngine(snapshot: snapshot, now: now.addingTimeInterval(10))
    let after = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.holds[0]))
        as? [String: Any])
    #expect(after["closedLid"] as? Bool != true)
    #expect(restored.holds[0].expiry == snapshot.holds[0].expiry)
  }

  @Test func overlappingClosedLidRequestsEndIndependentlyAndCanBeDisarmedTogether() throws {
    var engine = WakeEngine()
    let first = try engine.start(source: .manual, label: "First", closedLid: true)
    let other = try engine.start(source: .cli, label: "Second", closedLid: true)
    #expect(engine.desiredState.closedLid)
    engine.stop(id: first.id)
    #expect(engine.desiredState.closedLid)
    engine.setClosedLid(id: other.id, enabled: false)
    #expect(!engine.desiredState.closedLid)
    #expect(engine.desiredState.systemAwake)
    engine.setClosedLid(id: other.id, enabled: true)
    engine.clearClosedLidRequests()
    #expect(!engine.desiredState.closedLid)
    #expect(engine.holds.count == 1)
  }
}

struct ClosedLidGovernorTests {
  private let owner = UUID()
  private var safe: ClosedLidEnvironment {
    ClosedLidEnvironment(powerSource: .ac, thermal: .nominal, lidClosed: false)
  }

  @Test func missingSafetyInputsDefaultToUnknownRatherThanAssumingAC() {
    var governor = ClosedLidGovernor()
    #expect(throws: ClosedLidError.unsafe(.telemetryUnavailable)) {
      try governor.begin(owner: owner, policy: .init(), environment: .init(), now: 0)
    }
    #expect(governor.lease == nil)
  }

  @Test func leasesAreBoundedAndExpiredRenewalsCannotRecreateThem() throws {
    var governor = ClosedLidGovernor()
    let id = try governor.begin(owner: owner, policy: .init(), environment: safe, now: 0)
    #expect(governor.lease?.expiry == 90)
    #expect(try governor.heartbeat(owner: owner, id: id, environment: safe, now: 89) == nil)
    #expect(governor.lease?.expiry == 179)
    #expect(governor.reconcile(environment: safe, now: 179)?.reason == .leaseExpired)
    #expect(governor.lease == nil)
    #expect(throws: ClosedLidError.missingLease) {
      try governor.heartbeat(owner: owner, id: id, environment: safe, now: 180)
    }
  }

  @Test func anotherConnectionCannotRenewOrCancelTheLease() throws {
    var governor = ClosedLidGovernor()
    let id = try governor.begin(owner: owner, policy: .init(), environment: safe, now: 0)
    #expect(throws: ClosedLidError.notLeaseOwner) {
      try governor.heartbeat(owner: UUID(), id: id, environment: safe, now: 1)
    }
    #expect(governor.disconnected(owner: UUID(), environment: safe) == nil)
    #expect(governor.lease?.expiry == 90)
    #expect(throws: ClosedLidError.alreadyActive) {
      try governor.begin(owner: UUID(), policy: .init(), environment: safe, now: 2)
    }
    #expect(governor.disconnected(owner: owner, environment: safe)?.reason == .disconnected)
    #expect(governor.lease == nil)
  }

  @Test func thermalStopNeedsFreshExplicitEnableAndRequestsSleepWhenClosed() throws {
    var governor = ClosedLidGovernor()
    var environment = safe
    environment.lidClosed = true
    let id = try governor.begin(owner: owner, policy: .init(), environment: environment, now: 0)
    environment.thermal = .serious
    let result = try governor.heartbeat(owner: owner, id: id, environment: environment, now: 10)
    let stop = try #require(result)
    #expect(stop.reason == .thermal)
    #expect(stop.requestSleep)
    environment.thermal = .nominal
    #expect(governor.reconcile(environment: environment, now: 11) == nil)
    #expect(governor.lease == nil)
    #expect(throws: ClosedLidError.missingLease) {
      try governor.heartbeat(owner: owner, id: id, environment: environment, now: 12)
    }
    let fresh = try governor.begin(owner: owner, policy: .init(), environment: environment, now: 12)
    #expect(fresh != id)
  }

  @Test func lowBatteryAndMissingTelemetryVetoClosedLidEvenWithLowPowerOverride() throws {
    var environment = safe
    environment.powerSource = .battery
    environment.batteryPercent = 19
    var governor = ClosedLidGovernor()
    #expect(throws: ClosedLidError.unsafe(.lowBattery)) {
      try governor.begin(
        owner: owner, policy: .init(overrideLowPower: true), environment: environment, now: 0)
    }
    environment.batteryPercent = nil
    #expect(throws: ClosedLidError.unsafe(.telemetryUnavailable)) {
      try governor.begin(owner: owner, policy: .init(), environment: environment, now: 0)
    }
    environment.powerSource = .unknown
    #expect(throws: ClosedLidError.unsafe(.telemetryUnavailable)) {
      try governor.begin(owner: owner, policy: .init(), environment: environment, now: 0)
    }
    #expect(governor.lease == nil)
  }

  @Test func lowPowerOverrideDoesNotBypassThermalOrACOnlyGuards() throws {
    var environment = safe
    environment.lowPowerMode = true
    var governor = ClosedLidGovernor()
    #expect(throws: ClosedLidError.unsafe(.lowPowerMode)) {
      try governor.begin(owner: owner, policy: .init(), environment: environment, now: 0)
    }
    _ = try governor.begin(
      owner: owner, policy: .init(overrideLowPower: true), environment: environment, now: 0)
    environment.thermal = .critical
    #expect(governor.reconcile(environment: environment, now: 1)?.reason == .thermal)
    environment = safe
    environment.powerSource = .battery
    environment.batteryPercent = 100
    #expect(throws: ClosedLidError.unsafe(.requiresAC)) {
      try governor.begin(
        owner: owner, policy: .init(acOnly: true), environment: environment, now: 2)
    }
  }

  @Test func batteryTimeStartsWhenTheLidClosesAndRemainsBoundedDespiteHeartbeats() throws {
    var environment = safe
    environment.powerSource = .battery
    environment.batteryPercent = 80
    var governor = ClosedLidGovernor()
    let id = try governor.begin(
      owner: owner, policy: .init(maximumBatteryClosedSeconds: 60), environment: environment, now: 0
    )
    #expect(try governor.heartbeat(owner: owner, id: id, environment: environment, now: 80) == nil)
    environment.lidClosed = true
    #expect(governor.reconcile(environment: environment, now: 81) == nil)
    #expect(try governor.heartbeat(owner: owner, id: id, environment: environment, now: 140) == nil)
    let stopped = governor.reconcile(environment: environment, now: 141)
    #expect(stopped?.reason == .batteryTimeLimit)
    #expect(stopped?.requestSleep == true)
    #expect(governor.lease == nil)
  }

  @Test func invalidPolicyAndClockNeverCreateAnUnboundedLease() throws {
    var governor = ClosedLidGovernor()
    for policy in [
      ClosedLidPolicy(batteryFloor: 9), ClosedLidPolicy(maximumBatteryClosedSeconds: .infinity),
      ClosedLidPolicy(maximumBatteryClosedSeconds: 59),
    ] {
      #expect(throws: ClosedLidError.invalidPolicy) {
        try governor.begin(owner: owner, policy: policy, environment: safe, now: 0)
      }
    }
    #expect(throws: ClosedLidError.unsafe(.invalidClock)) {
      try governor.begin(owner: owner, policy: .init(), environment: safe, now: .nan)
    }
    _ = try governor.begin(owner: owner, policy: .init(), environment: safe, now: 10)
    #expect(governor.reconcile(environment: safe, now: 9)?.reason == .invalidClock)
    #expect(governor.lease == nil)
  }

  @Test func restartInvalidatesLeasesAndOrdinaryDisableKeepsTheOpenMacAwake() throws {
    var original = ClosedLidGovernor()
    let id = try original.begin(owner: owner, policy: .init(), environment: safe, now: 0)
    var restarted = ClosedLidGovernor()
    #expect(restarted.generation != original.generation)
    #expect(throws: ClosedLidError.missingLease) {
      try restarted.heartbeat(owner: owner, id: id, environment: safe, now: 1)
    }
    let result = original.stop(reason: .disabled, environment: safe)
    let stopped = try #require(result)
    #expect(!stopped.requestSleep)
    #expect(original.lease == nil)
  }
}
