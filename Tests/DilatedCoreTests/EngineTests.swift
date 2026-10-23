import Foundation
import Testing

@testable import DilatedCore

struct EngineTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func overlappingHoldsMergeAndEndIndependently() throws {
    var engine = WakeEngine()
    let first = try engine.start(source: .manual, label: "Timer", duration: 60, now: now)
    let second = try engine.start(source: .cli, label: "Build", displayAwake: true, now: now)
    #expect(engine.desiredState.systemAwake)
    #expect(engine.desiredState.displayAwake)
    engine.stop(id: second.id)
    #expect(engine.holds.map(\.id) == [first.id])
    #expect(!engine.desiredState.displayAwake)
    engine.tick(now: now.addingTimeInterval(60))
    #expect(!engine.desiredState.systemAwake)
  }

  @Test func stopPausesAllAutomationButAllowsManualHolds() throws {
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Manual", now: now)
    let lease = try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    engine.stopAll()
    #expect(engine.holds.isEmpty)
    #expect(engine.automationPaused)
    #expect(throws: WakeError.automationPaused) {
      try engine.start(source: .cli, label: "CLI", now: now)
    }
    #expect(throws: WakeError.automationPaused) {
      try engine.renew(id: lease.id, duration: 60, now: now)
    }
    _ = try engine.start(source: .manual, label: "Manual", now: now)
    #expect(engine.automationPaused)
    engine.resumeAutomation()
    _ = try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    #expect(engine.holds.count == 2)
  }

  @Test func restorationKeepsDeadlinesAndPauseButNotIndefiniteOrLeases() throws {
    var original = WakeEngine()
    let timer = try original.start(source: .manual, label: "Timer", duration: 600, now: now)
    _ = try original.start(source: .manual, label: "Forever", now: now)
    _ = try original.start(source: .lease, label: "Agent", duration: 600, now: now)
    var restored = WakeEngine(snapshot: original.snapshot, now: now.addingTimeInterval(100))
    #expect(restored.holds == [timer])
    restored.tick(now: now.addingTimeInterval(601))
    #expect(restored.holds.isEmpty)
    original.stopAll()
    let paused = WakeEngine(snapshot: original.snapshot, now: now)
    #expect(paused.automationPaused)
  }

  @Test func quitDiscardsTimersWithoutChangingAnExplicitPause() throws {
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Timer", duration: 60, now: now)
    engine.quit()
    #expect(WakeEngine(snapshot: engine.snapshot, now: now).holds.isEmpty)
    engine.stopAll()
    engine.quit()
    #expect(engine.snapshot.automationPaused)
  }

  @Test func leasesExpireAndOnlyLeaseIDsCanBeRenewed() throws {
    var engine = WakeEngine()
    let lease = try engine.start(source: .lease, label: "Same label", duration: 10, now: now)
    let other = try engine.start(source: .lease, label: "Same label", duration: 10, now: now)
    #expect(lease.id != other.id)
    try engine.renew(id: lease.id, duration: 30, now: now.addingTimeInterval(5))
    engine.tick(now: now.addingTimeInterval(11))
    #expect(engine.holds.map(\.id) == [lease.id])
    engine.tick(now: now.addingTimeInterval(36))
    #expect(throws: WakeError.holdNotFound) {
      try engine.renew(id: lease.id, duration: 30, now: now.addingTimeInterval(36))
    }
    let manual = try engine.start(source: .manual, label: "Manual", duration: 60, now: now)
    #expect(throws: WakeError.notRenewable) {
      try engine.renew(id: manual.id, duration: 60, now: now)
    }
  }

  @Test func lowPowerModeEndsAllSourcesExceptExplicitOverrides() throws {
    var engine = WakeEngine()
    _ = try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    let override = try engine.start(
      source: .manual, label: "Override", lowPowerOverride: true, now: now)
    engine.updatePower(PowerState(lowPowerMode: true), now: now)
    #expect(engine.holds == [override])
    #expect(throws: WakeError.lowPowerMode) {
      try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    }
    #expect(engine.attention?.contains("Low Power Mode") == true)
  }

  @Test func batteryGuardAllowsACAndBlocksLowBatteryStartsAndRestores() throws {
    var engine = WakeEngine(batteryFloor: 20)
    _ = try engine.start(source: .manual, label: "Timer", duration: 60, now: now)
    let saved = engine.snapshot
    engine.updatePower(PowerState(onBattery: true, batteryPercent: 19), now: now)
    #expect(engine.holds.isEmpty)
    #expect(throws: WakeError.lowBattery) {
      try engine.start(source: .manual, label: "Manual", now: now)
    }
    let restored = WakeEngine(
      snapshot: saved, now: now, power: PowerState(onBattery: true, batteryPercent: 19),
      batteryFloor: 20)
    #expect(restored.holds.isEmpty)
    engine.updatePower(PowerState(onBattery: false, batteryPercent: 19), now: now)
    _ = try engine.start(source: .manual, label: "AC", now: now)
  }

  @Test func batteryOverrideOnlyAppliesToTheApprovedHold() throws {
    var engine = WakeEngine(
      power: PowerState(onBattery: true, batteryPercent: 15), batteryFloor: 20)
    let approved = try engine.start(
      source: .manual, label: "Approved", batteryOverride: true, now: now)
    engine.updatePower(PowerState(onBattery: true, batteryPercent: 14), now: now)
    #expect(engine.holds == [approved])
    #expect(throws: WakeError.lowBattery) {
      try engine.start(source: .manual, label: "Other", now: now)
    }
  }
  @Test func invalidDurationsNeverCreateHolds() {
    var engine = WakeEngine()
    for duration in [0.0, -1, .infinity, .nan] {
      #expect(throws: WakeError.invalidDuration) {
        try engine.start(source: .lease, label: "Bad", duration: duration, now: now)
      }
    }
    #expect(engine.holds.isEmpty)
  }

  @Test func extensionRetainsTheOriginalDeadlineAndRejectsIndefinite() throws {
    var engine = WakeEngine()
    let timer = try engine.start(source: .manual, label: "Timer", duration: 60, now: now)
    try engine.extend(id: timer.id, by: 30, now: now.addingTimeInterval(20))
    #expect(engine.holds.first?.expiry == now.addingTimeInterval(90))
    let indefinite = try engine.start(source: .manual, label: "Forever", now: now)
    #expect(throws: WakeError.notTimed) { try engine.extend(id: indefinite.id, by: 30, now: now) }
  }
}
