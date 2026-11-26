import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct LeavingModeIntegrationTests {
  @Test func menuAndCLIArmAndCancelTheSameRequest() async throws {
    let fixture = LeavingFixture()
    defer { fixture.close() }
    let model = try #require(fixture.model)
    let menu = AwakeMenu.make(model: model, openSettings: {})
    let arm = try #require(menu.items.first { $0.title == "Sleep when holds finish" })
    _ = NSApp.sendAction(try #require(arm.action), to: arm.target, from: arm)
    #expect(model.engine.leavingPending)
    let pending = AwakeMenu.make(model: model, openSettings: {})
    #expect(pending.items.contains { $0.title == "Sleep when idle is armed" })
    let cancel = try #require(pending.items.first { $0.title == "Cancel sleep when idle" })
    _ = NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: cancel)
    #expect(!model.engine.leavingPending)
    let command = try #require(CLIInput.parse(["leaving", "--json"]).request)
    let response = await model.control(command)
    #expect(response.ok && response.leavingPending == true)
    let off = try #require(CLIInput.parse(["leaving", "--cancel"]).request)
    #expect(await model.control(off).ok)
    #expect(!model.engine.leavingPending && fixture.sleepRequests == 0)
  }

  @Test(arguments: [false, true])
  func idleGraceRequestsTheFakeBackendOnceWithoutRetrying(failSleep: Bool) async throws {
    let fixture = LeavingFixture(failSleep: failSleep)
    defer { fixture.close() }
    try fixture.model.leaveWhenIdle()
    fixture.model.tick()
    fixture.clock = fixture.clock.addingTimeInterval(4)
    fixture.model.tick()
    #expect(fixture.sleepRequests == 0)
    fixture.clock = fixture.clock.addingTimeInterval(1)
    fixture.model.tick()
    try await fixture.waitForRequest()
    #expect(!fixture.model.engine.leavingPending)
    #expect((fixture.model.message?.contains("Sleep refused") == true) == failSleep)
    fixture.clock = fixture.clock.addingTimeInterval(100)
    fixture.model.tick()
    #expect(fixture.sleepRequests == 1)
  }

  @Test func shutdownCancelsAQueuedSleepRequest() async throws {
    let fixture = LeavingFixture()
    defer { fixture.close() }
    try fixture.model.leaveWhenIdle()
    fixture.model.tick()
    fixture.clock = fixture.clock.addingTimeInterval(5)
    fixture.model.tick()
    fixture.model.shutdown()
    await Task.yield()
    #expect(!fixture.model.engine.leavingPending && fixture.sleepRequests == 0)
  }

  @Test func newHoldStopAndSystemSleepCancelBeforeAnyBackendCall() throws {
    let fixture = LeavingFixture()
    defer { fixture.close() }
    try fixture.model.leaveWhenIdle()
    fixture.model.tick()
    fixture.model.start(duration: 60)
    #expect(!fixture.model.engine.leavingPending)
    try fixture.model.leaveWhenIdle()
    fixture.model.stopAll()
    #expect(!fixture.model.engine.leavingPending)
    fixture.model.settings.stopOnSystemSleep = false
    try fixture.model.leaveWhenIdle()
    fixture.model.handleSystemTransition(.sleep)
    #expect(!fixture.model.engine.leavingPending)
    fixture.clock = fixture.clock.addingTimeInterval(100)
    fixture.model.tick()
    #expect(fixture.sleepRequests == 0)
  }

  @Test func closedLidCleanupSleepCancelsLeavingBeforeItCanRequestASecondSleep() async throws {
    let power = LeavingLidPower()
    let transport = LocalClosedLidTransport(
      power: power,
      environment: {
        .init(powerSource: .ac, batteryPercent: 100, thermal: .nominal, lidClosed: true)
      },
      tickInterval: .seconds(3600))
    let fixture = LeavingFixture(closedLid: ClosedLidController(transport: transport))
    defer { fixture.close() }
    let model = try #require(fixture.model)
    model.settings.stopOnSystemSleep = false
    await power.onSleep { @MainActor [weak model] in model?.handleSystemTransition(.sleep) }
    model.start(duration: 60)
    let hold = try #require(model.engine.holds.first)
    try await model.setClosedLid(id: hold.id, enabled: true)
    try model.leaveWhenIdle()
    model.stop(id: hold.id)
    try await model.synchronizeClosedLid()
    #expect(await power.sleepRequests == 1)
    #expect(!model.engine.leavingPending)
    fixture.clock = fixture.clock.addingTimeInterval(100)
    model.tick()
    #expect(fixture.sleepRequests == 0)
  }
}

@MainActor private final class LeavingFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var clock = Date()
  var sleepRequests = 0
  var model: AppModel!
  init(failSleep: Bool = false, closedLid: ClosedLidController? = nil) {
    _ = NSApplication.shared
    model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: LeavingAssertions(), closedLid: closedLid ?? inertClosedLid(),
      closedLidPermission: readyPermissionModel(),
      leavingClock: { [unowned self] in clock },
      requestSleep: { [unowned self] in
        sleepRequests += 1
        if failSleep { throw InputError("Sleep refused") }
      })
  }
  func close() {
    model.shutdown()
    model = nil
    try? FileManager.default.removeItem(at: directory)
  }
  func waitForRequest() async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while sleepRequests == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try #require(sleepRequests == 1)
  }
}

private actor LeavingLidPower: ClosedLidPowerControlling {
  private var disabled = false
  private var didSleep: (@Sendable () async -> Void)?
  private(set) var sleepRequests = 0
  func onSleep(_ action: @escaping @Sendable () async -> Void) { didSleep = action }
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    self.disabled = disabled
    return await readback()
  }
  func readback() async -> ClosedLidReadback {
    .init(effectiveDisabled: disabled, storedDisabled: disabled)
  }
  func sleep() async throws {
    sleepRequests += 1
    await didSleep?()
  }
}

@MainActor private final class LeavingAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {}
  func releaseAll() {}
}
