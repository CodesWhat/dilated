import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct LocalClosedLidTransportTests {
  @Test func enableAndDisableRunThroughTheSudoRunner() async throws {
    let fixture = await LocalFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    #expect(controller.active)
    #expect(await fixture.runner.readback().confirmedEnabled)
    try await controller.disable()
    #expect(!controller.active)
    #expect(await fixture.runner.readback().confirmedDisabled)
    let calls = await fixture.runner.calls
    #expect(calls.suffix(2) == [.setSleepDisabled(true), .setSleepDisabled(false)])
  }

  @Test func theLeaseExpiresAndRevertsWhileTheMainActorIsBlocked() async throws {
    let fixture = await LocalFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    #expect(await fixture.runner.readback().confirmedEnabled)
    fixture.clock.advance(by: ClosedLidGovernor.leaseSeconds + 1)
    // Nothing on the main actor runs here: no heartbeat, no refresh, no await.
    blockMainActor(seconds: 0.4)
    #expect(await fixture.runner.readback().confirmedDisabled)
    try await controller.refresh()
    #expect(!controller.active)
  }

  @Test func aGuardTriggersARevertWithoutAnyAppRequest() async throws {
    let fixture = await LocalFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    fixture.inputs.overheat()
    await waitUntil { await fixture.runner.readback().confirmedDisabled }
    try await controller.refresh()
    #expect(!controller.active)
  }

  @Test func deniedPermissionOnEnableFailsClosed() async throws {
    let fixture = await LocalFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    await fixture.runner.deny()
    await #expect(throws: (any Error).self) { try await controller.enable(policy: .init()) }
    #expect(!controller.active && !controller.hasLease)
    #expect(controller.lastError != nil)
    #expect(await fixture.runner.readback().confirmedDisabled)
    #expect(await fixture.runner.everEnabled == false)
  }

  @Test func deniedPermissionOnDisableStaysFailedAndRetriesEachTick() async throws {
    let fixture = await LocalFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    await fixture.runner.deny()
    await #expect(throws: (any Error).self) { try await controller.disable() }
    #expect(!controller.active)
    #expect(await fixture.runner.readback().confirmedEnabled)
    let attempts = await fixture.runner.disableAttempts
    await waitUntil { await fixture.runner.disableAttempts > attempts + 1 }
    #expect(await fixture.runner.readback().confirmedEnabled)
    await fixture.runner.allow()
    await waitUntil { await fixture.runner.readback().confirmedDisabled }
  }

  @Test func theFlagDefaultsOffAndKeepsTheHelperTransport() {
    let defaults = UserDefaults(suiteName: "local-lid-\(UUID().uuidString)")!
    #expect(defaults.bool(forKey: LocalClosedLidTransport.defaultsKey) == false)
    let off = ClosedLidController.configured(defaults: defaults)
    #expect(!off.hasLease)
    #expect(!off.usesLocalTransport)
    defaults.set(true, forKey: LocalClosedLidTransport.defaultsKey)
    let on = ClosedLidController.configured(defaults: defaults)
    defer { on.invalidate() }
    #expect(on.usesLocalTransport)
  }
}

private func blockMainActor(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("condition not met in time")
}

@MainActor private struct LocalFixture {
  let runner = FakeSudoRunner()
  let inputs = LocalInputs()
  let clock = LocalClock()
  let transport: LocalClosedLidTransport
  init() async {
    let runner = runner
    let inputs = inputs
    let clock = clock
    transport = LocalClosedLidTransport(
      power: SerialPowerDriver(runner: runner, readback: { await runner.readback() }),
      environment: { inputs.read() }, clock: { clock.now() }, tickInterval: .milliseconds(20))
    await waitUntil { await runner.calls.contains(.setSleepDisabled(false)) }
    try? await Task.sleep(for: .milliseconds(60))
  }
  func controller() -> ClosedLidController {
    ClosedLidController(
      transport: transport, expectedBuild: { LocalClosedLidTransport.buildIdentity })
  }
}

private actor FakeSudoRunner: PowerCommandRunning {
  private(set) var calls: [PowerCommand] = []
  private(set) var everEnabled = false
  private(set) var disableAttempts = 0
  private var value = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)
  private var denied = false

  func run(_ command: PowerCommand) throws {
    calls.append(command)
    if command == .setSleepDisabled(false) { disableAttempts += 1 }
    if denied, case .setSleepDisabled = command { throw ClosedLidPowerError.permissionUnavailable }
    if case .setSleepDisabled(let disabled) = command {
      if disabled { everEnabled = true }
      value = ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
    }
  }
  func readback() -> ClosedLidReadback { value }
  func deny() { denied = true }
  func allow() { denied = false }
}

private final class LocalClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval = 0
  func now() -> TimeInterval { lock.withLock { value } }
  func advance(by seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class LocalInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var thermal = ClosedLidThermal.nominal
  func read() -> ClosedLidEnvironment {
    lock.withLock {
      ClosedLidEnvironment(powerSource: .ac, thermal: thermal, lidClosed: false)
    }
  }
  func overheat() { lock.withLock { thermal = .serious } }
}
