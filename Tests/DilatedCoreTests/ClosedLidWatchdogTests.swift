import Foundation
import Testing

@testable import DilatedCore

private let offState = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)

private actor WatchdogPower: ClosedLidPowerControlling {
  private(set) var calls: [Bool] = []
  private var failing: Bool
  private var failuresRemaining: Int
  init(failing: Bool = false, failFirst: Int = 0) {
    self.failing = failing
    failuresRemaining = failFirst
  }
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    calls.append(disabled)
    if failing { throw ClosedLidPowerError.commandFailed(1) }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw ClosedLidPowerError.commandFailed(1)
    }
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
      generation: generation,
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
      generation: generation,
      pollInterval: .seconds(10),
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
      generation: UUID(),
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
      generation: generation,
      readMarker: { box.read() }, waitForExit: { box.set(nil) }, power: power,
      clearMarker: {}, sleep: forever)
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
  }

  @Test func aFailedRevertKeepsTheMarkerUntilItIsCancelled() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower(failing: true)
    let sleeps = DurationLog()
    let watchdog = ClosedLidWatchdog(
      generation: generation, pollInterval: .seconds(1000),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) },
      sleep: { duration in
        if duration == .seconds(1000) { try await Task.sleep(for: .seconds(3600)) }
        if sleeps.record(duration) >= 3 { throw CancellationError() }
      })
    #expect(await watchdog.run() == .revertFailed)
    #expect(box.read() != nil)
    #expect(await power.calls == [false, false, false])
  }

  @Test func revertBackoffDoublesFromFiveSecondsToAFiveMinuteCap() {
    let schedule = (0..<9).map { ClosedLidWatchdog.revertBackoff(attempt: $0) }
    #expect(
      schedule == [5, 10, 20, 40, 80, 160, 300, 300, 300].map { Duration.seconds($0) })
  }

  @Test func aFailingRevertRetriesWithBackoffUntilItConfirms() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower(failFirst: 7)
    let sleeps = DurationLog()
    let watchdog = ClosedLidWatchdog(
      generation: generation, pollInterval: .seconds(1000),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) },
      sleep: { duration in
        if duration == .seconds(1000) { try await Task.sleep(for: .seconds(3600)) }
        _ = sleeps.record(duration)
      })
    #expect(await watchdog.run() == .reverted)
    #expect(sleeps.values == [5, 10, 20, 40, 80, 160, 300].map { Duration.seconds($0) })
    #expect(await power.calls.count == 8)
    #expect(box.read() == nil)
  }

  @Test func theRetryStopsOnceTheMarkerIsNoLongerOurs() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower(failing: true)
    let watchdog = ClosedLidWatchdog(
      generation: generation, pollInterval: .seconds(1000),
      readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: {},
      sleep: { duration in
        if duration == .seconds(1000) { try await Task.sleep(for: .seconds(3600)) }
        box.set(marker(UUID()))
      })
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls == [false])
  }

  @Test func thereIsNoLifetimeCapWhileTheMarkerIsOurs() async {
    let generation = UUID()
    let box = MarkerBox(marker(generation))
    let power = WatchdogPower()
    let polls = Counter()
    // 10,000 polls at 10s each is well past 24 hours of simulated time.
    let watchdog = ClosedLidWatchdog(
      generation: generation, pollInterval: .seconds(10),
      readMarker: { box.read() },
      waitForExit: { try? await Task.sleep(for: .seconds(3600)) }, power: power,
      clearMarker: {},
      sleep: { duration in
        guard duration == .seconds(10) else { return }
        if polls.next() == 10_000 { box.set(nil) }
        await Task.yield()
      })
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
  }

  @Test func theLockStopsTheWatchdogRevertingANewGeneration() async throws {
    let old = UUID()
    let store = ClosedLidMarkerStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "lid-watchdog-lock-\(UUID().uuidString)"))
    try store.write(marker(old))
    // The app holds the lock while it replaces the marker.
    let appLock = try await store.acquireLock()
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: old, pollInterval: .seconds(1000),
      readMarker: { store.read() }, waitForExit: {}, power: power,
      clearMarker: { store.clear(generation: old) },
      acquireLock: {
        guard let lock = try? await store.acquireLock() else { return nil }
        return { lock.release() }
      })
    let outcome = Task { await watchdog.run() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await power.calls.isEmpty)
    try store.write(marker(UUID()))
    appLock.release()
    #expect(await outcome.value == .markerGone)
    #expect(await power.calls.isEmpty)
    #expect(store.read() != nil)
  }

  @Test func aZeroStartTimeMarkerIsNeverActedOn() async {
    let generation = UUID()
    let zero = ClosedLidSessionMarker(
      pid: 1, processStartMicros: 0, generation: generation, enabledAt: Date())
    let box = MarkerBox(zero)
    let power = WatchdogPower()
    let watchdog = ClosedLidWatchdog(
      generation: generation, readMarker: { box.read() }, waitForExit: {}, power: power,
      clearMarker: { box.set(nil) }, sleep: forever)
    #expect(await watchdog.run() == .markerGone)
    #expect(await power.calls.isEmpty)
    #expect(box.read() != nil)
  }

  @Test func killingARealAppProcessRestoresSleep() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["20"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
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
      generation: generation,
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
    for _ in 0..<500 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func waitingOnAnExitedProcessReturnsAtOnce() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    let pid = child.processIdentifier
    let start = ProcessStartTime.micros(pid: pid) ?? 0
    for _ in 0..<500 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
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

private final class DurationLog: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [Duration] = []
  var values: [Duration] { lock.withLock { log } }
  func record(_ duration: Duration) -> Int {
    lock.withLock {
      log.append(duration)
      return log.count
    }
  }
}

struct ClosedLidWatchdogCommandTests {
  private let marker = "/tmp/x/closed-lid-session.json"
  private let generation = UUID()

  private func arguments(_ overrides: [String: String?] = [:], extra: [String] = []) -> [String] {
    var values: [String: String?] = [
      "--pid": "123", "--marker": marker, "--generation": generation.uuidString,
    ]
    for (key, value) in overrides { values[key] = value }
    let flat = values.sorted { $0.key < $1.key }.flatMap { key, value in
      value.map { [key, $0] } ?? []
    }
    return [ClosedLidWatchdogCommand.name] + flat + extra
  }

  @Test func parsesTheFullArgumentList() {
    let launch = ClosedLidWatchdogCommand.parse(arguments())
    #expect(
      launch
        == ClosedLidWatchdogLaunch(
          pid: 123, marker: URL(fileURLWithPath: marker), generation: generation))
  }

  @Test func rejectsMalformedArguments() {
    #expect(ClosedLidWatchdogCommand.parse([]) == nil)
    #expect(ClosedLidWatchdogCommand.parse(["status"]) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--pid": nil])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--marker": nil])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--generation": nil])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--pid": "0"])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--pid": "-5"])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--pid": "abc"])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--marker": "relative/path"])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(["--generation": "nope"])) == nil)
    #expect(ClosedLidWatchdogCommand.parse(arguments(extra: ["--dangling"])) == nil)
  }

  @Test func runDoesNothingWithoutAMatchingUsableMarker() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lid-command-\(UUID().uuidString)")
    let store = ClosedLidMarkerStore(directory: directory)
    let launch = ClosedLidWatchdogLaunch(pid: 123, marker: store.file, generation: generation)
    #expect(await ClosedLidWatchdogCommand.run(launch) == 0)
    // A different generation, a different pid and a zero start time all exit without acting.
    for stored in [
      ClosedLidSessionMarker(
        pid: 123, processStartMicros: 5, generation: UUID(),
        enabledAt: Date(timeIntervalSince1970: 1)),
      ClosedLidSessionMarker(
        pid: 999, processStartMicros: 5, generation: generation,
        enabledAt: Date(timeIntervalSince1970: 1)),
      ClosedLidSessionMarker(
        pid: 123, processStartMicros: 0, generation: generation,
        enabledAt: Date(timeIntervalSince1970: 1)),
    ] {
      try store.write(stored)
      #expect(await ClosedLidWatchdogCommand.run(launch) == 0)
      #expect(store.read() == stored)
    }
  }
}
