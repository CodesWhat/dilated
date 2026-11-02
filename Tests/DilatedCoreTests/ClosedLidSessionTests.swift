import Foundation
import Testing

@testable import DilatedCore

private let disabledState = ClosedLidReadback(effectiveDisabled: true, storedDisabled: true)
private let enabledState = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)

/// Records every call and whether the marker existed when it happened.
private actor RecordingPower: ClosedLidPowerControlling {
  private let store: ClosedLidMarkerStore
  private(set) var calls: [String] = []
  private(set) var state: ClosedLidReadback
  private var failing = false

  init(store: ClosedLidMarkerStore, state: ClosedLidReadback = enabledState) {
    self.store = store
    self.state = state
  }

  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    calls.append("\(disabled ? "disable" : "enable") marker=\(store.read() != nil)")
    if failing { throw ClosedLidPowerError.permissionUnavailable }
    state = disabled ? disabledState : enabledState
    return state
  }
  func readback() async -> ClosedLidReadback { state }
  func sleep() async throws {}
  func fail(_ value: Bool) { failing = value }
  func setState(_ value: ClosedLidReadback) { state = value }
}

private final class LaunchLog: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [ClosedLidWatchdogLaunch] = []
  var values: [ClosedLidWatchdogLaunch] { lock.withLock { log } }
  func record(_ launch: ClosedLidWatchdogLaunch) { lock.withLock { log.append(launch) } }
}

private func makeStore() -> ClosedLidMarkerStore {
  ClosedLidMarkerStore(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(
      "lid-session-\(UUID().uuidString)"))
}

private func staleMarker(pid: Int32 = 999_999, start: Int64 = 1_000) -> ClosedLidSessionMarker {
  ClosedLidSessionMarker(
    pid: pid, processStartMicros: start, generation: UUID(),
    enabledAt: Date(timeIntervalSince1970: 1))
}

struct ClosedLidSessionTests {
  @Test func theMarkerIsWrittenBeforeEnableAndClearedOnlyAfterConfirmedRevert() async throws {
    let store = makeStore()
    let power = RecordingPower(store: store)
    let launches = LaunchLog()
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, launchWatchdog: { launches.record($0) })
    _ = try await guardian.setSleepDisabled(true)
    let marker = try #require(store.read())
    #expect(marker.pid == getpid())
    #expect(marker.processStartMicros == ProcessStartTime.micros(pid: getpid()))
    #expect(await power.calls == ["disable marker=true"])
    _ = try await guardian.setSleepDisabled(false)
    #expect(store.read() == nil)
    #expect(await power.calls.last == "enable marker=true")
  }

  @Test func aRevertThatIsNotConfirmedKeepsTheMarker() async throws {
    let store = makeStore()
    let power = RecordingPower(store: store)
    let guardian = ClosedLidSessionGuard(power: power, store: store)
    _ = try await guardian.setSleepDisabled(true)
    await power.fail(true)
    await #expect(throws: (any Error).self) { try await guardian.setSleepDisabled(false) }
    #expect(store.read() != nil)
  }

  @Test func oneWatchdogLaunchesPerGeneration() async throws {
    let store = makeStore()
    let launches = LaunchLog()
    let power = RecordingPower(store: store)
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, launchWatchdog: { launches.record($0) })
    _ = try await guardian.setSleepDisabled(true)
    _ = try await guardian.setSleepDisabled(true)
    #expect(launches.values.count == 1)
    let first = try #require(launches.values.first)
    #expect(first.generation == store.read()?.generation)
    #expect(first.pid == getpid())
    _ = try await guardian.setSleepDisabled(false)
    _ = try await guardian.setSleepDisabled(true)
    #expect(launches.values.count == 2)
    #expect(launches.values[1].generation != first.generation)
  }

  @Test func aFailedWatchdogLaunchRefusesToEnable() async throws {
    struct Refused: Error {}
    let store = makeStore()
    let power = RecordingPower(store: store)
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, launchWatchdog: { _ in throw Refused() })
    await #expect(throws: Refused.self) { try await guardian.setSleepDisabled(true) }
    #expect(store.read() == nil)
    #expect(await power.calls.isEmpty)
  }

  @Test func aFailedEnableClearsTheMarkerAndTheSession() async throws {
    let store = makeStore()
    let launches = LaunchLog()
    let power = RecordingPower(store: store)
    await power.fail(true)
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, launchWatchdog: { launches.record($0) })
    await #expect(throws: (any Error).self) { try await guardian.setSleepDisabled(true) }
    #expect(store.read() == nil)
    await power.fail(false)
    _ = try await guardian.setSleepDisabled(true)
    // The failed session was dropped, so this is a fresh generation with its own watchdog.
    #expect(launches.values.count == 2)
    #expect(launches.values[1].generation != launches.values[0].generation)
    #expect(store.read()?.generation == launches.values[1].generation)
  }

  @Test func anUnreadableOrZeroStartTimeRefusesToEnable() async throws {
    for start: Int64? in [nil, 0] {
      let store = makeStore()
      let launches = LaunchLog()
      let power = RecordingPower(store: store)
      let guardian = ClosedLidSessionGuard(
        power: power, store: store, startMicros: { _ in start },
        launchWatchdog: { launches.record($0) })
      await #expect(throws: ClosedLidSessionError.self) {
        try await guardian.setSleepDisabled(true)
      }
      #expect(store.read() == nil)
      #expect(launches.values.isEmpty)
      #expect(await power.calls.isEmpty)
    }
  }

  @Test func theGuardWaitsForTheLockBeforeWritingAMarkerOrEnabling() async throws {
    let store = makeStore()
    let power = RecordingPower(store: store)
    let held = try await store.acquireLock()
    let guardian = ClosedLidSessionGuard(power: power, store: store)
    let enabling = Task { try await guardian.setSleepDisabled(true) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(store.read() == nil)
    #expect(await power.calls.isEmpty)
    held.release()
    _ = try await enabling.value
    #expect(store.read() != nil)
    #expect(await power.calls == ["disable marker=true"])
  }

  @Test func aLockThatNeverFreesTimesOutInsteadOfBlocking() async throws {
    let store = makeStore()
    let held = try await store.acquireLock()
    defer { held.release() }
    await #expect(throws: ClosedLidSessionError.lockTimeout) {
      _ = try await store.acquireLock(timeout: .milliseconds(100))
    }
  }

  @Test func relaunchWithADeadPidRevertsAndClears() async throws {
    let store = makeStore()
    try store.write(staleMarker())
    let power = RecordingPower(store: store, state: disabledState)
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, startMicros: { _ in nil })
    _ = try await guardian.setSleepDisabled(false)
    #expect(await guardian.recovery == .reverted)
    #expect(store.read() == nil)
    #expect(await power.state.confirmedDisabled)
  }

  @Test func aReusedPidWithADifferentStartTimeCountsAsDead() async throws {
    let store = makeStore()
    try store.write(staleMarker(pid: 4242, start: 1_000))
    let power = RecordingPower(store: store, state: disabledState)
    let guardian = ClosedLidSessionGuard(power: power, store: store, startMicros: { _ in 2_000 })
    _ = try await guardian.setSleepDisabled(false)
    #expect(await guardian.recovery == .reverted)
    #expect(store.read() == nil)
  }

  @Test func aLiveProcessWithTheSameStartTimeIsLeftAlone() async throws {
    let store = makeStore()
    try store.write(staleMarker(pid: 4242, start: 1_000))
    let power = RecordingPower(store: store, state: disabledState)
    let guardian = ClosedLidSessionGuard(power: power, store: store, startMicros: { _ in 1_000 })
    let observed = try await guardian.setSleepDisabled(false)
    #expect(observed == disabledState)
    #expect(await guardian.recovery == .activeElsewhere)
    #expect(await power.calls.isEmpty)
    #expect(store.read() != nil)
  }

  @Test func disabledSleepWithNoMarkerIsLeftAlone() async throws {
    let store = makeStore()
    let power = RecordingPower(store: store, state: disabledState)
    let guardian = ClosedLidSessionGuard(power: power, store: store)
    let observed = try await guardian.setSleepDisabled(false)
    #expect(observed == disabledState)
    #expect(await guardian.recovery == .foreignSleepDisabled)
    #expect(await power.calls.isEmpty)
    // Once the other tool lets go, the normal path resumes.
    await power.setState(enabledState)
    _ = try await guardian.setSleepDisabled(false)
    #expect(await guardian.recovery == .clean)
  }

  @Test func aFailedRelaunchRevertKeepsTheMarkerAndFailsClosed() async throws {
    let store = makeStore()
    let marker = staleMarker()
    try store.write(marker)
    let power = RecordingPower(store: store, state: disabledState)
    await power.fail(true)
    let guardian = ClosedLidSessionGuard(power: power, store: store, startMicros: { _ in nil })
    await #expect(throws: (any Error).self) { try await guardian.setSleepDisabled(false) }
    await #expect(throws: (any Error).self) { try await guardian.setSleepDisabled(true) }
    guard case .failed = await guardian.recovery else {
      Issue.record("expected a failed recovery")
      return
    }
    #expect(store.read() == marker)
    // Permission comes back: the next call reverts and clears.
    await power.fail(false)
    _ = try await guardian.setSleepDisabled(false)
    #expect(await guardian.recovery == .reverted)
    #expect(store.read() == nil)
  }

  @Test func aManualRestoreClearsAFailedRevertOnlyWhenMacOSConfirmsIt() async throws {
    let store = makeStore()
    let marker = staleMarker()
    try store.write(marker)
    let power = RecordingPower(store: store, state: disabledState)
    await power.fail(true)
    let guardian = ClosedLidSessionGuard(power: power, store: store, startMicros: { _ in nil })
    await #expect(throws: (any Error).self) { try await guardian.setSleepDisabled(false) }
    // Sleep is still disabled: nothing changes.
    #expect(await guardian.acknowledgeManualRestore() == false)
    #expect(store.read() == marker)
    // The password-backed restore worked.
    await power.setState(enabledState)
    #expect(await guardian.acknowledgeManualRestore() == true)
    #expect(await guardian.recovery == .reverted)
    #expect(store.read() == nil)
  }

  @Test func aStaleMarkerIsRevertedBeforeANewSessionStarts() async throws {
    let store = makeStore()
    try store.write(staleMarker())
    let power = RecordingPower(store: store, state: disabledState)
    let guardian = ClosedLidSessionGuard(
      power: power, store: store, startMicros: { $0 == 999_999 ? nil : 5_000 })
    _ = try await guardian.setSleepDisabled(true)
    let calls = await power.calls
    #expect(calls.count == 2)
    #expect(calls[0].hasPrefix("enable"))
    #expect(calls[1].hasPrefix("disable"))
  }

  @Test func clearIgnoresAMarkerFromAnotherGeneration() throws {
    let store = makeStore()
    let marker = staleMarker()
    try store.write(marker)
    store.clear(generation: UUID())
    #expect(store.read() == marker)
    store.clear(generation: marker.generation)
    #expect(store.read() == nil)
  }

  @Test func watchdogArgumentsRoundTrip() throws {
    let launch = ClosedLidWatchdogLaunch(
      pid: 123, marker: URL(fileURLWithPath: "/tmp/x/closed-lid-session.json"),
      generation: UUID())
    #expect(
      ClosedLidWatchdogCommand.parse(ClosedLidWatchdogCommand.arguments(for: launch)) == launch)
    #expect(ClosedLidWatchdogCommand.parse(["status"]) == nil)
    #expect(ClosedLidWatchdogCommand.parse([ClosedLidWatchdogCommand.name, "--pid", "1"]) == nil)
  }
}
