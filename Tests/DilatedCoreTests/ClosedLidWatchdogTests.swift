import Foundation
import Testing

@testable import DilatedCore

private let offState = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)

private actor WatchdogPower: ClosedLidPowerControlling {
  private(set) var calls: [Bool] = []
  private var failing: Bool
  init(failing: Bool = false) { self.failing = failing }
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    calls.append(disabled)
    if failing { throw ClosedLidPowerError.commandFailed(1) }
    return offState
  }
  func readback() async -> ClosedLidReadback { offState }
  func sleep() async throws {}
}

private final class MarkerBox: @unchecked Sendable {
  private let lock = NSLock()
  private var marker: ClosedLidSessionMarker?
  init(_ marker: ClosedLidSessionMarker?) { self.marker = marker }
  func read() -> ClosedLidSessionMarker? { lock.withLock { marker } }
  func set(_ value: ClosedLidSessionMarker?) { lock.withLock { marker = value } }
}

private func marker(_ generation: UUID, pid: Int32 = 1) -> ClosedLidSessionMarker {
  ClosedLidSessionMarker(
    pid: pid, processStartMicros: 1, generation: generation, enabledAt: Date())
}

private let forever: @Sendable (Duration) async throws -> Void = { _ in
  try await Task.sleep(for: .seconds(3600))
}

struct ClosedLidWatchdogTests {
  @Test func appExitRevertsAndClearsTheMarker() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(100),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) }, sleep: forever)
    #expect(await watchdog.run() == .reverted)
    #expect(await power.calls == [false])
    #expect(box.read() == nil)
  }

  @Test func aMarkerThatDisappearsEndsTheWatchdogWithoutReverting() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower()
    let polls = Counter()
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(100), pollInterval: .seconds(10),
      readMarker: { box.read() },
      waitForExit: { try? await Task.sleep(for: .seconds(3600)) }, power: power,
      clearMarker: {},
      sleep: { duration in
        if duration == .seconds(10) {
          if polls.next() == 2 { box.set(nil) }
          try await Task.sleep(for: .milliseconds(5))
        } else {
          try await Task.sleep(for: .seconds(3600))
        }
      })
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
  }

  @Test func aNewGenerationIsNotRevertedByTheOldWatchdog() async {
    let box = MarkerBox(marker(UUID()))
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: UUID(), maxLifetime: .seconds(100),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) }, sleep: forever)
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
    #expect(box.read() != nil)
  }

  @Test func theMarkerGoingAwayAtTheMomentOfExitDoesNotRevert() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(100),
      readMarker: { box.read() }, waitForExit: { box.set(nil) }, power: power,
      clearMarker: {}, sleep: forever)
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
  }

  @Test func aFailedRevertKeepsTheMarker() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower(failing: true)
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(100),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) }, sleep: forever)
    #expect(await watchdog.run() == .revertFailed)
    #expect(box.read() != nil)
  }

  @Test func theLifetimeCapEndsTheWatchdogQuietly() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(100), pollInterval: .seconds(10),
      readMarker: { box.read() },
      waitForExit: { try? await Task.sleep(for: .seconds(3600)) }, power: power,
      clearMarker: {},
      sleep: { duration in
        if duration == .seconds(100) { return }
        try await Task.sleep(for: .seconds(3600))
      })
    #expect(await watchdog.run() == .expired)
    #expect(await power.calls.isEmpty)
  }

  @Test func killingARealAppProcessRestoresSleep() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["300"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let pid = child.processIdentifier
    let start = try #require(ProcessStartTime.micros(pid: pid))
    let generation = UUID()
    let store = ClosedLidMarkerStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "lid-watchdog-\(UUID().uuidString)"))
    try store.write(
      ClosedLidSessionMarker(
        pid: pid, processStartMicros: start, generation: generation, enabledAt: Date()))
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: generation, maxLifetime: .seconds(60),
      readMarker: { store.read() },
      waitForExit: { await ProcessExit.wait(pid: pid, startMicros: start) },
      power: power, clearMarker: { store.clear(generation: generation) })
    let outcome = Task { await watchdog.run() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await power.calls.isEmpty)
    kill(pid, SIGKILL)
    #expect(await outcome.value == .reverted)
    #expect(await power.calls == [false])
    #expect(store.read() == nil)
    child.waitUntilExit()
  }

  @Test func waitingOnAnExitedProcessReturnsAtOnce() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    let pid = child.processIdentifier
    let start = ProcessStartTime.micros(pid: pid) ?? 0
    child.waitUntilExit()
    await ProcessExit.wait(pid: pid, startMicros: start)
    await ProcessExit.wait(pid: getpid(), startMicros: 1)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
