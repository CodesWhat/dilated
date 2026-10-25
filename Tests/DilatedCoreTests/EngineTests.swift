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

  @Test func stopPauseSurvivesRecoveryForEverySourceAndOverride() throws {
    let sources: [HoldSource] = [
      .manual, .cli, .lease, .runner, .url, .trigger, .shortcut, .appleScript,
    ]
    for source in sources {
      for overrides in 0..<4 {
        let lowPowerOverride = overrides & 1 != 0
        let batteryOverride = overrides & 2 != 0
        var engine = WakeEngine()
        let lease = try engine.start(source: .lease, label: "Before Stop", duration: 60, now: now)
        engine.stopAll(now: now)
        let manual = try engine.start(
          source: .manual, label: "After Stop", duration: 60,
          lowPowerOverride: lowPowerOverride, batteryOverride: batteryOverride,
          closedLid: true, now: now)
        let saved = try JSONEncoder().encode(engine.snapshot)
        engine = WakeEngine(
          snapshot: try JSONDecoder().decode(EngineSnapshot.self, from: saved),
          now: now.addingTimeInterval(1))
        #expect(engine.automationPaused)
        #expect(engine.holds.map(\.id) == [manual.id])
        #expect(engine.holds.first?.expiry == manual.expiry)
        #expect(!engine.desiredState.closedLid)

        if source == .manual {
          _ = try engine.start(
            source: source, label: "Explicit manual", duration: 30,
            lowPowerOverride: lowPowerOverride, batteryOverride: batteryOverride, now: now)
          #expect(engine.holds.count == 2)
        } else {
          #expect(throws: WakeError.automationPaused) {
            try engine.start(
              source: source, label: "Automation", duration: 30,
              lowPowerOverride: lowPowerOverride, batteryOverride: batteryOverride,
              closedLid: true, now: now)
          }
          #expect(engine.holds.map(\.id) == [manual.id])
        }
        #expect(engine.automationPaused)
        #expect(throws: WakeError.automationPaused) {
          try engine.renew(id: lease.id, duration: 30, now: now)
        }
        engine.stopAll(now: now)
        #expect(engine.holds.isEmpty)
        #expect(engine.automationPaused)
      }
    }
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
  @Test func acBatteryFloorHonorsTheThresholdAndPowerSourceChanges() throws {
    var engine = WakeEngine(
      power: .init(onBattery: false, batteryPercent: 20), batteryFloor: 20,
      batteryFloorIgnoresAC: false)
    try engine.start(source: .manual, label: "At the floor", duration: 120, now: now)
    engine.updatePower(.init(onBattery: false, batteryPercent: 19), now: now)
    #expect(engine.holds.isEmpty)
    #expect(engine.takeHistoryEvents().last?.endReason == .lowBattery)
    #expect(throws: WakeError.lowBattery) {
      try engine.start(source: .lease, label: "Agent", duration: 60, now: now)
    }
    engine.batteryFloorIgnoresAC = true
    try engine.start(source: .manual, label: "AC exemption", now: now)
    engine.updatePower(.init(onBattery: true, batteryPercent: 19), now: now)
    #expect(engine.holds.isEmpty)
    engine.batteryFloor = nil
    engine.batteryFloorIgnoresAC = false
    try engine.start(source: .manual, label: "Floor off", now: now)
    #expect(engine.holds.count == 1)
  }
  @Test func acBatteryOverrideRestoresOnlyItsOwnTimerAndDoesNotOverrideLowPowerMode() throws {
    var engine = WakeEngine(batteryFloor: 20, batteryFloorIgnoresAC: false)
    try engine.start(source: .manual, label: "Ordinary", duration: 120, now: now)
    let approved = try engine.start(
      source: .manual, label: "Approved", duration: 180, batteryOverride: true, now: now)
    var restored = WakeEngine(
      snapshot: engine.snapshot, now: now.addingTimeInterval(1),
      power: .init(onBattery: false, batteryPercent: 15), batteryFloor: 20,
      batteryFloorIgnoresAC: false)
    #expect(restored.holds == [approved])
    restored.updatePower(.init(onBattery: false, batteryPercent: 14, lowPowerMode: true), now: now)
    #expect(restored.holds.isEmpty)
    #expect(throws: WakeError.lowPowerMode) {
      try restored.start(source: .manual, label: "Battery only", batteryOverride: true, now: now)
    }
    try restored.start(
      source: .manual, label: "Both overrides", lowPowerOverride: true, batteryOverride: true,
      now: now)
    restored.stopAll(now: now)
    #expect(restored.holds.isEmpty && restored.automationPaused)
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

  @Test func restoreKeepsDeadlinesDropsExpiredAndNeverRestoresClosedLid() throws {
    var source = WakeEngine()
    let expired = try source.start(source: .manual, label: "Old", duration: 60, now: now)
    let timer = try source.start(
      source: .manual, label: "Timer", duration: 600, displayAwake: true, lowPowerOverride: true,
      batteryOverride: true, now: now)
    let lid = try source.start(
      source: .cli, label: "Lid", duration: 600, closedLid: true, now: now)
    let lease = try source.start(source: .lease, label: "Lease", duration: 600, now: now)
    let forever = try source.start(source: .manual, label: "Forever", now: now)
    var engine = WakeEngine()
    engine.stopAll(now: now)
    engine.resumeAutomation()
    let later = now.addingTimeInterval(120)
    engine.restore(holds: source.holds, now: later)
    #expect(!engine.holds.contains { $0.id == expired.id })
    #expect(engine.holds.first { $0.id == timer.id } == timer)
    #expect(engine.holds.first { $0.id == lid.id }?.closedLid == nil)
    #expect(engine.holds.first { $0.id == lid.id }?.expiry == lid.expiry)
    #expect(engine.holds.contains { $0.id == lease.id })
    #expect(engine.holds.contains { $0.id == forever.id })
    engine.restore(holds: source.holds, now: later)
    #expect(engine.holds.count == 4)
  }
}

@Test func userReturnRestorationExcludesHoldsStoppedWhileAway() throws {
  var engine = WakeEngine()
  let kept = try engine.start(source: .manual, label: "kept", duration: 60)
  let ended = try engine.start(source: .lease, label: "ended", duration: 60)
  engine.suspendForUserSwitch(capture: true)
  #expect(engine.holds.isEmpty && engine.automationPaused)
  #expect(engine.userReturnRestoration?.holds.count == 2)
  engine.stop(id: ended.id)
  let restored = engine.resumeAfterUserReturn()
  #expect(restored?.holds == [kept] && restored?.wasPaused == false)
  #expect(engine.holds == [kept] && !engine.automationPaused)
  #expect(engine.userReturnRestoration == nil)
  #expect(engine.resumeAfterUserReturn() == nil)
}

@Test func everyOtherStopPathClearsTheUserReturnRestoration() throws {
  for clear in [
    { (engine: inout WakeEngine) in engine.stopAll() },
    { (engine: inout WakeEngine) in engine.quit() },
    { (engine: inout WakeEngine) in engine.resumeAutomation() },
  ] {
    var engine = WakeEngine()
    try engine.start(source: .manual, label: "a", duration: 60)
    engine.suspendForUserSwitch(capture: true)
    #expect(engine.userReturnRestoration != nil)
    clear(&engine)
    #expect(engine.userReturnRestoration == nil)
    #expect(engine.resumeAfterUserReturn() == nil)
  }
  var engine = WakeEngine()
  try engine.start(source: .manual, label: "a", duration: 60)
  engine.suspendForUserSwitch(capture: false)
  #expect(engine.userReturnRestoration == nil)
}
