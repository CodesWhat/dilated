import Foundation
import Testing

@testable import DilatedCore

private func makeStore() -> ClosedLidMarkerStore {
  ClosedLidMarkerStore(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(
      "lid-heartbeat-\(UUID().uuidString)"))
}

private func marker(_ generation: UUID, pid: Int32, start: Int64) -> ClosedLidSessionMarker {
  ClosedLidSessionMarker(
    pid: pid, processStartMicros: start, generation: generation, enabledAt: Date())
}

private let safeEnvironment: @Sendable () -> ClosedLidEnvironment = {
  ClosedLidEnvironment(powerSource: .ac, thermal: .nominal, lidClosed: false)
}

private let enableRequest = HelperRequest(
  action: .enable, policy: .init())

/// Records calls and holds a sleep-disabled flag the test can flip from outside.
private actor FakePower: ClosedLidPowerControlling {
  private var disabled = false
  private(set) var calls: [Bool] = []
  func setSleepDisabled(_ value: Bool) async throws -> ClosedLidReadback {
    calls.append(value)
    disabled = value
    return await readback()
  }
  func readback() async -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
  }
  func sleep() async throws {}
  func revertExternally() { disabled = false }
}

private final class Tally: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func add() { lock.withLock { value += 1 } }
}

private final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { current } }
  func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// A monotonic clock the test advances by hand.
private final class ManualMonotonic: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Duration.zero
  var now: Duration { lock.withLock { current } }
  func advance(_ duration: Duration) { lock.withLock { current += duration } }
}

/// Stands in for the poll timer: the test fires each poll itself, in lockstep with the clock
/// and the heartbeat, so no real elapsed time decides anything.
private final class ManualTicks: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  var ticker: @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    { [self] _, handler in
      lock.withLock { self.handler = handler }
      return { [self] in lock.withLock { self.handler = nil } }
    }
  }
  /// Waits (by yielding, not by time) until `run()` has registered its poll.
  func waitUntilArmed() async {
    while lock.withLock({ handler == nil }) { await Task.yield() }
  }
  func fire() { lock.withLock { handler }?() }
}

private func watchdog(
  _ generation: UUID, store: ClosedLidMarkerStore, power: FakePower, pid: Int32, start: Int64,
  timeout: Duration = .milliseconds(300), pollInterval: Duration = .milliseconds(20),
  monotonic: @escaping @Sendable () -> Duration = ClosedLidWatchdog.suspendingNow,
  ticker: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void =
    ClosedLidWatchdog.timerTicker
) -> ClosedLidWatchdog {
  ClosedLidWatchdog(
    generation: generation, pollInterval: pollInterval,
    readMarker: { store.read() },
    onExit: { handler in
      ProcessExit.register(pid: pid, startMicros: start, handler: handler)
    },
    power: power, clearMarker: { store.clear(generation: generation) },
    readHeartbeat: { store.readHeartbeat() }, heartbeatTimeout: timeout,
    monotonic: monotonic, ticker: ticker)
}

struct ClosedLidHeartbeatTests {
  @Test func aHeartbeatThatStopsChangingRevertsWithoutKillingTheApp() async throws {
    let store = makeStore()
    let generation = UUID()
    // A live pid with a matching start time: only the stall can trigger the revert.
    let start = try #require(ProcessStartTime.micros(pid: getpid()))
    try store.write(marker(generation, pid: getpid(), start: start))
    store.writeHeartbeat(generation: generation, count: 1, at: Date())
    let power = FakePower()
    let clock = ManualMonotonic()
    let ticks = ManualTicks()
    let dog = watchdog(
      generation, store: store, power: power, pid: getpid(), start: start,
      monotonic: { clock.now }, ticker: ticks.ticker)
    let outcome = Task { await dog.run() }
    await ticks.waitUntilArmed()
    clock.advance(.milliseconds(299))
    ticks.fire()
    clock.advance(.milliseconds(1))
    ticks.fire()
    #expect(await outcome.value == .reverted)
    #expect(await power.calls == [false])
    #expect(store.read() == nil)
  }

  @Test func aHeartbeatThatKeepsChangingNeverReverts() async throws {
    let store = makeStore()
    let generation = UUID()
    let start = try #require(ProcessStartTime.micros(pid: getpid()))
    try store.write(marker(generation, pid: getpid(), start: start))
    store.writeHeartbeat(generation: generation, count: 0, at: Date())
    let power = FakePower()
    let clock = ManualMonotonic()
    let ticks = ManualTicks()
    let dog = watchdog(
      generation, store: store, power: power, pid: getpid(), start: start,
      monotonic: { clock.now }, ticker: ticks.ticker)
    let outcome = Task { await dog.run() }
    await ticks.waitUntilArmed()
    // Three times the timeout, wall-clock field frozen: only the count moves.
    let frozen = Date(timeIntervalSince1970: 1_800_000_000)
    for count in 1...45 {
      store.writeHeartbeat(generation: generation, count: UInt64(count), at: frozen)
      clock.advance(.milliseconds(20))
      ticks.fire()
    }
    #expect(await power.calls.isEmpty)
    store.clear(generation: generation)
    ticks.fire()
    #expect(await outcome.value == .markerGone)
    #expect(await power.calls.isEmpty)
  }

  @Test func aFutureTimestampAloneDoesNotRevert() async throws {
    let store = makeStore()
    let generation = UUID()
    let start = try #require(ProcessStartTime.micros(pid: getpid()))
    try store.write(marker(generation, pid: getpid(), start: start))
    let power = FakePower()
    let clock = ManualMonotonic()
    let ticks = ManualTicks()
    let dog = watchdog(
      generation, store: store, power: power, pid: getpid(), start: start,
      monotonic: { clock.now }, ticker: ticks.ticker)
    let outcome = Task { await dog.run() }
    await ticks.waitUntilArmed()
    for count in 1...30 {
      store.writeHeartbeat(
        generation: generation, count: UInt64(count),
        at: Date(timeIntervalSinceNow: 86_400 * 365))
      clock.advance(.milliseconds(20))
      ticks.fire()
    }
    #expect(await power.calls.isEmpty)
    store.clear(generation: generation)
    ticks.fire()
    #expect(await outcome.value == .markerGone)
  }

  @Test func theGuardBeatsWhileActiveAndStopsAfterTheSessionEnds() async throws {
    let store = makeStore()
    let clock = MutableClock()
    let guardian = ClosedLidSessionGuard(
      power: FakePower(), store: store, now: { clock.now }, heartbeatInterval: 10)
    await guardian.beat()
    #expect(store.readHeartbeat() == nil)
    _ = try await guardian.setSleepDisabled(true)
    let first = try #require(store.readHeartbeat())
    clock.advance(5)
    await guardian.beat()
    #expect(store.readHeartbeat() == first)
    clock.advance(6)
    await guardian.beat()
    let second = try #require(store.readHeartbeat())
    #expect(second != first)
    _ = try await guardian.setSleepDisabled(false)
    #expect(store.readHeartbeat() == nil)
    clock.advance(60)
    await guardian.beat()
    #expect(store.readHeartbeat() == nil)
  }

  @Test func theScriptBeatFiresOncePerIntervalAndOnlyWhileASessionIsActive() async throws {
    let clock = MutableClock()
    let beats = Tally()
    let guardian = ClosedLidSessionGuard(
      power: FakePower(), store: makeStore(), now: { clock.now },
      heartbeatInterval: ClosedLidSessionGuard.scriptHeartbeatInterval,
      scriptBeat: { beats.add() })
    #expect(ClosedLidSessionGuard.scriptHeartbeatInterval == 20)
    await guardian.beat()
    #expect(beats.count == 0)
    _ = try await guardian.setSleepDisabled(true)
    #expect(beats.count == 1)
    for _ in 0..<19 {
      clock.advance(1)
      await guardian.beat()
    }
    #expect(beats.count == 1)
    clock.advance(1)
    await guardian.beat()
    #expect(beats.count == 2)
    clock.advance(40)
    await guardian.beat()
    #expect(beats.count == 3)
    _ = try await guardian.setSleepDisabled(false)
    clock.advance(60)
    await guardian.beat()
    #expect(beats.count == 3)
  }

  @Test func theServiceBeatsOnItsTickOnlyWhileTheLeaseIsActive() async throws {
    let beats = Tally()
    let service = ClosedLidService(
      power: FakePower(), environment: safeEnvironment, clock: { 0 }, buildIdentity: "test",
      heartbeat: { beats.add() })
    await service.start()
    await service.tick()
    #expect(beats.count == 0)
    let owner = UUID()
    let reply = await service.handle(enableRequest, owner: owner)
    #expect(reply.ok)
    await service.tick()
    await service.tick()
    #expect(beats.count >= 2)
    let disable = HelperRequest(
      action: .disable,
      leaseID: reply.state?.leaseID)
    _ = await service.handle(disable, owner: owner)
    let before = beats.count
    await service.tick()
    await service.tick()
    #expect(beats.count == before)
  }

  @Test func resumingAfterAHangRevertEndsTheSessionWithoutReEnabling() async throws {
    let store = makeStore()
    let power = FakePower()
    let guardian = ClosedLidSessionGuard(power: power, store: store)
    let service = ClosedLidService(
      power: guardian, environment: safeEnvironment, clock: { 0 }, buildIdentity: "test",
      heartbeat: { await guardian.beat() })
    await service.start()
    let owner = UUID()
    let reply = await service.handle(enableRequest, owner: owner)
    #expect(reply.ok)
    let generation = try #require(store.read()?.generation)
    #expect(store.readHeartbeat() != nil)
    // The watchdog reverted while the app was hung.
    await power.revertExternally()
    store.clear(generation: generation)
    store.clearHeartbeat()
    await service.tick()
    #expect(store.read() == nil)
    #expect(await power.readback().confirmedDisabled)
    #expect(await power.calls.filter { $0 }.count == 1)
    let status = await service.handle(
      HelperRequest(action: .status),
      owner: owner)
    #expect(status.state?.enabled == false)
    #expect(status.state?.stopReason == .leaseExpired)
    #expect(status.state?.phase == .off)
  }

  @Test func aRealStoppedAppProcessIsRevertedByItsStalledHeartbeat() async throws {
    let store = makeStore()
    let generation = UUID()
    try FileManager.default.createDirectory(
      at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A stand-in app: a shell loop that keeps rewriting the heartbeat file.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = [
      "-c", "i=0; while true; do i=$((i+1)); echo $i > \"$1\"; sleep 0.05; done", "sh",
      store.heartbeatFile.path,
    ]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    let pid = child.processIdentifier
    defer {
      kill(pid, SIGCONT)
      if child.isRunning { child.terminate() }
    }
    let start = try #require(ProcessStartTime.micros(pid: pid))
    try store.write(marker(generation, pid: pid, start: start))
    let power = FakePower()
    let dog = watchdog(
      generation, store: store, power: power, pid: pid, start: start,
      timeout: .seconds(5), pollInterval: .milliseconds(100))
    let outcome = Task { await dog.run() }
    // Well under the timeout, so a slow runner can't make the live loop look stalled.
    try await Task.sleep(for: .seconds(2))
    #expect(await power.calls.isEmpty)
    kill(pid, SIGSTOP)
    #expect(await outcome.value == .reverted)
    #expect(await power.calls == [false])
    #expect(store.read() == nil)
    #expect(child.isRunning)
    kill(pid, SIGCONT)
    kill(pid, SIGKILL)
    for _ in 0..<500 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
  }
}
