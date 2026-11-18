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
    let sleeps = SleepLog()
    let fixture = await LocalFixture(sleeps: sleeps)
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    await fixture.runner.deny()
    await #expect(throws: (any Error).self) { try await controller.disable() }
    #expect(!controller.active)
    #expect(await fixture.runner.readback().confirmedEnabled)
    let attempts = await fixture.runner.disableAttempts
    await waitUntil { await fixture.runner.disableAttempts > attempts + 6 }
    #expect(await fixture.runner.readback().confirmedEnabled)
    let seconds = sleeps.values.map { Int($0.components.seconds) }
    let backoffSteps = Array(seconds.drop { $0 != 1 })
    #expect(backoffSteps.starts(with: [1, 2, 4, 8, 16, 30, 30]))
    #expect(backoffSteps.allSatisfy { $0 <= 30 })
    await fixture.runner.allow()
    await waitUntil { await fixture.runner.readback().confirmedDisabled }
    // Recovered with no lease, so the loop goes to sleep instead of ticking on.
    try await Task.sleep(for: .milliseconds(100))
    let settled = sleeps.values.count
    try await Task.sleep(for: .milliseconds(150))
    #expect(sleeps.values.count == settled)
  }

  @Test func aLaunchWithNoPermissionNeverRunsTheCommand() async throws {
    let runner = FakeSudoRunner()
    await runner.deny()
    let fixture = GuardedFixture(runner: runner, tickInterval: .milliseconds(5))
    defer { fixture.controller.invalidate() }
    try await Task.sleep(for: .milliseconds(150))
    try await fixture.controller.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await runner.calls.isEmpty)
    #expect(!fixture.controller.restorationPending)
  }

  @Test func aLaunchWithTheScriptMissingNeverRunsIt() async throws {
    let launcher = CountingLauncher()
    let runner = UserScriptPowerRunner(launcher: launcher)
    let readback = FakeSudoRunner()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lid-guard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = ClosedLidSessionGuard(
      power: SerialPowerDriver(runner: runner, readback: { await readback.readback() }),
      store: ClosedLidMarkerStore(directory: directory))
    let transport = LocalClosedLidTransport(
      sessionGuard: session, power: session, tickInterval: .milliseconds(5))
    let controller = ClosedLidController(
      transport: transport, expectedBuild: { LocalClosedLidTransport.buildIdentity })
    defer { controller.invalidate() }
    try await Task.sleep(for: .milliseconds(150))
    try await controller.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(launcher.count == 0)
  }

  @Test func theTickSleepsWithNoLeaseAndWakesOnRequests() async throws {
    let reads = EnvironmentReads()
    let sleeps = SleepLog()
    let fixture = await LocalFixture(sleeps: sleeps, reads: reads)
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await Task.sleep(for: .milliseconds(100))
    let idleReads = reads.count
    let idleSleeps = sleeps.values.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(reads.count == idleReads)
    #expect(sleeps.values.count == idleSleeps)
    try await controller.enable(policy: .init())
    await waitUntil { reads.count > idleReads + 4 }
    try await controller.disable()
    try await Task.sleep(for: .milliseconds(100))
    let stopped = reads.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(reads.count == stopped)
  }

  @Test func anExpiredLeaseIsRevertedByTheTickAndThenTheTickSleeps() async throws {
    let reads = EnvironmentReads()
    let fixture = await LocalFixture(reads: reads)
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    fixture.clock.advance(by: ClosedLidGovernor.leaseSeconds + 1)
    await waitUntil { await fixture.runner.readback().confirmedDisabled }
    try await Task.sleep(for: .milliseconds(100))
    let settled = reads.count
    try await Task.sleep(for: .milliseconds(200))
    #expect(reads.count == settled)
  }

  @Test func quitIsNotBlockedBySleepAnotherAppDisabled() async throws {
    let runner = FakeSudoRunner()
    let fixture = GuardedFixture(runner: runner, tickInterval: .milliseconds(5))
    let model = AppModel(
      endpoint: .init(stateDirectory: fixture.directory), power: { .init() },
      closedLid: fixture.controller)
    defer { model.shutdown() }
    try await Task.sleep(for: .milliseconds(50))
    await runner.setValue(.init(effectiveDisabled: true, storedDisabled: true))
    try await fixture.controller.refresh()
    #expect(fixture.controller.restorationPending)
    #expect(model.updateActivity == .recovering)
    #expect(await model.prepareToQuit())
    #expect(fixture.controller.state?.foreignSleepDisabled == true)
    #expect(await runner.calls.isEmpty)
    #expect(await runner.readback().confirmedEnabled)
  }

  @Test func aForeignDisableAtLaunchIsPushedAndDoesNotBlockUpdates() async throws {
    let runner = FakeSudoRunner()
    await runner.setValue(.init(effectiveDisabled: true, storedDisabled: true))
    let fixture = GuardedFixture(runner: runner, tickInterval: .milliseconds(5))
    let model = AppModel(
      endpoint: .init(stateDirectory: fixture.directory), power: { .init() },
      closedLid: fixture.controller)
    defer { model.shutdown() }
    await waitUntil {
      await MainActor.run { fixture.controller.state?.foreignSleepDisabled == true }
    }
    #expect(model.updateActivity == .idle)
    #expect(await runner.calls.isEmpty)
  }

  @Test func aTransientFailedRestoreClearsItsStaleStateWithoutAnyRequest() async throws {
    let runner = FakeSudoRunner()
    let fixture = GuardedFixture(
      runner: runner, tickInterval: .milliseconds(5),
      backoff: RetryBackoff(initial: .milliseconds(5), cap: .milliseconds(20)))
    let model = AppModel(
      endpoint: .init(stateDirectory: fixture.directory), power: { .init() },
      closedLid: fixture.controller)
    defer { model.shutdown() }
    try await fixture.controller.enable(policy: .init())
    await runner.deny()
    await #expect(throws: (any Error).self) { try await fixture.controller.disable() }
    #expect(fixture.controller.restorationPending)
    #expect(model.updateActivity == .recovering)
    #expect(await model.prepareToQuit() == false)
    await runner.allow()
    await waitUntil { await MainActor.run { !fixture.controller.restorationPending } }
    #expect(model.updateActivity == .idle)
    #expect(await model.prepareToQuit())
  }

  @Test func aBlockedMainActorNeverStallsAnOwnedRestoreRetry() async throws {
    let runner = FakeSudoRunner()
    await runner.setValue(.init(effectiveDisabled: true, storedDisabled: true))
    await runner.deny()
    Task.detached {
      try? await Task.sleep(for: .milliseconds(100))
      await runner.allow()
    }
    // A stale marker after a reboot: the first restore fails and its state is pushed to a main
    // actor that never gets to run it.
    let fixture = GuardedFixture(
      runner: runner, tickInterval: .milliseconds(5),
      backoff: RetryBackoff(initial: .milliseconds(5), cap: .milliseconds(20)), staleMarker: true)
    defer { fixture.controller.invalidate() }
    blockMainActor(seconds: 0.6)
    #expect(await runner.readback().confirmedDisabled)
    #expect(await runner.calls.count > 1)
  }

  @Test func aForeignDisableThatClearsAllowsAnEnableAfterAStatusRequest() async throws {
    let runner = FakeSudoRunner()
    await runner.setValue(.init(effectiveDisabled: true, storedDisabled: true))
    let fixture = GuardedFixture(runner: runner, tickInterval: .milliseconds(5))
    defer { fixture.controller.invalidate() }
    await waitUntil {
      await MainActor.run { fixture.controller.state?.foreignSleepDisabled == true }
    }
    await runner.setValue(.init(effectiveDisabled: false, storedDisabled: false))
    try await fixture.controller.refresh()
    #expect(fixture.controller.state?.foreignSleepDisabled == false)
    #expect(fixture.controller.state?.ready == true)
    try await fixture.controller.enable(policy: .init())
    #expect(fixture.controller.active)
    #expect(await runner.calls == [.setSleepDisabled(true)])
  }

  @Test func aRequestMidRetryDoesNotSuppressTheResolvedPush() async throws {
    let runner = FakeSudoRunner()
    let fixture = GuardedFixture(
      runner: runner, tickInterval: .milliseconds(5),
      backoff: RetryBackoff(initial: .milliseconds(5), cap: .milliseconds(20)))
    defer { fixture.controller.invalidate() }
    try await fixture.controller.enable(policy: .init())
    await runner.deny()
    await #expect(throws: (any Error).self) { try await fixture.controller.disable() }
    #expect(fixture.controller.restorationPending)
    await runner.allow()
    await runner.holdNextRestore()
    await waitUntil { await runner.holding }
    // The service is mid-retry, so this request records a disabling state with sleep still off.
    try await fixture.controller.refresh()
    #expect(fixture.controller.state?.phase == .disabling)
    #expect(fixture.controller.restorationPending)
    await runner.release()
    await waitUntil { await MainActor.run { !fixture.controller.restorationPending } }
    #expect(fixture.controller.state?.phase == .off)
  }

  @Test func backoffDoublesToTheCapAndResetsOnRequest() {
    let backoff = RetryBackoff(initial: .seconds(1), cap: .seconds(30))
    let steps = (0..<8).map { _ in Int(backoff.next().components.seconds) }
    #expect(steps == [1, 2, 4, 8, 16, 30, 30, 30])
    backoff.reset()
    #expect(backoff.next() == .seconds(1))
  }

  @Test(arguments: [false, true])
  func theControllerAlwaysUsesTheLocalTransportWhateverTheRetiredFlagSays(stale: Bool) {
    let key = "DilatedLocalClosedLidTransport"
    let previous = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(stale, forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "local-lid-\(UUID().uuidString)")
    let controller = ClosedLidController.configured(stateDirectory: directory)
    defer { controller.invalidate() }
    #expect(controller.localTransport != nil)
    #expect(!controller.hasLease)
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

private final class SleepLog: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [Duration] = []
  var values: [Duration] { lock.withLock { log } }
  func record(_ duration: Duration) { lock.withLock { log.append(duration) } }
}

@MainActor private struct LocalFixture {
  let runner = FakeSudoRunner()
  let inputs = LocalInputs()
  let clock = LocalClock()
  let transport: LocalClosedLidTransport
  init(sleeps: SleepLog? = nil, reads: EnvironmentReads? = nil) async {
    let runner = runner
    let inputs = inputs
    let clock = clock
    transport = LocalClosedLidTransport(
      power: SerialPowerDriver(runner: runner, readback: { await runner.readback() }),
      environment: {
        reads?.bump()
        return inputs.read()
      }, clock: { clock.now() }, tickInterval: .milliseconds(20),
      sleep: { duration in
        guard let sleeps else { return try await Task.sleep(for: duration) }
        sleeps.record(duration)
        try await Task.sleep(for: .milliseconds(5))
      })
    await waitUntil { await runner.calls.contains(.setSleepDisabled(false)) }
    try? await Task.sleep(for: .milliseconds(60))
  }
  func controller() -> ClosedLidController {
    ClosedLidController(
      transport: transport, expectedBuild: { LocalClosedLidTransport.buildIdentity })
  }
}

final class EnvironmentReads: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  var count: Int { lock.withLock { reads } }
  func bump() { lock.withLock { reads += 1 } }
}

private final class CountingLauncher: UserScriptLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private var runs = 0
  var count: Int { lock.withLock { runs } }
  func run(arguments: [String]) async -> UserScriptRun {
    lock.withLock { runs += 1 }
    return .missing
  }
}

/// The real session guard over a fake runner, behind the local transport.
@MainActor private struct GuardedFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "lid-guarded-\(UUID().uuidString)")
  let controller: ClosedLidController
  init(
    runner: FakeSudoRunner, tickInterval: Duration, backoff: RetryBackoff = RetryBackoff(),
    staleMarker: Bool = false
  ) {
    let store = ClosedLidMarkerStore(directory: directory)
    if staleMarker {
      try? store.write(
        ClosedLidSessionMarker(
          pid: 999_999, processStartMicros: 1_000, generation: UUID(),
          enabledAt: Date(timeIntervalSince1970: 1)))
    }
    let session = ClosedLidSessionGuard(
      power: SerialPowerDriver(runner: runner, readback: { await runner.readback() }),
      store: store)
    controller = ClosedLidController(
      transport: LocalClosedLidTransport(
        sessionGuard: session, power: session,
        environment: { .init(powerSource: .ac, thermal: .nominal, lidClosed: false) },
        tickInterval: tickInterval, backoff: backoff),
      expectedBuild: { LocalClosedLidTransport.buildIdentity })
  }
}

private actor FakeSudoRunner: PowerCommandRunning {
  private(set) var calls: [PowerCommand] = []
  private(set) var everEnabled = false
  private(set) var disableAttempts = 0
  private var value = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)
  private var denied = false
  private var holdDisable = false
  private(set) var holding = false
  private var waiter: CheckedContinuation<Void, Never>?

  func run(_ command: PowerCommand) async throws {
    calls.append(command)
    if holdDisable, !denied, command == .setSleepDisabled(false) {
      holdDisable = false
      holding = true
      await withCheckedContinuation { waiter = $0 }
      holding = false
    }
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
  /// Makes the next restore wait in the runner until `release()`.
  func holdNextRestore() { holdDisable = true }
  func release() {
    waiter?.resume()
    waiter = nil
  }
  func setValue(_ readback: ClosedLidReadback) { value = readback }
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
