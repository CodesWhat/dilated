import Darwin
import Foundation

/// Restores sleep after the app dies. Runs in a detached `dilated` process; this is the logic,
/// with every dependency injected so it can be tested without sudo or a real crash.
public struct ClosedLidWatchdog: Sendable {
  public enum Outcome: Equatable, Sendable {
    case reverted
    /// The app exited but sleep couldn't be restored. The marker stays for the relaunch revert.
    case revertFailed
    /// The session ended normally, or a newer one replaced it.
    case markerGone
    case expired
  }

  private enum Event: Sendable { case exited, markerGone, expired }

  private let generation: UUID
  private let maxLifetime: Duration
  private let pollInterval: Duration
  private let readMarker: @Sendable () -> ClosedLidSessionMarker?
  private let waitForExit: @Sendable () async -> Void
  private let power: any ClosedLidPowerControlling
  private let clearMarker: @Sendable () -> Void
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    generation: UUID, maxLifetime: Duration, pollInterval: Duration = .seconds(10),
    readMarker: @escaping @Sendable () -> ClosedLidSessionMarker?,
    waitForExit: @escaping @Sendable () async -> Void,
    power: any ClosedLidPowerControlling,
    clearMarker: @escaping @Sendable () -> Void,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.generation = generation
    self.maxLifetime = maxLifetime
    self.pollInterval = pollInterval
    self.readMarker = readMarker
    self.waitForExit = waitForExit
    self.power = power
    self.clearMarker = clearMarker
    self.sleep = sleep
  }

  private var markerIsOurs: Bool { readMarker()?.generation == generation }

  public func run() async -> Outcome {
    guard markerIsOurs else { return .markerGone }
    let event = await withTaskGroup(of: Event?.self) { group in
      group.addTask {
        await waitForExit()
        return Task.isCancelled ? nil : .exited
      }
      group.addTask {
        while (try? await sleep(pollInterval)) != nil {
          if !markerIsOurs { return .markerGone }
        }
        return nil
      }
      group.addTask {
        (try? await sleep(maxLifetime)) == nil ? nil : .expired
      }
      var first: Event?
      for await event in group {
        if let event {
          first = event
          group.cancelAll()
          break
        }
      }
      return first ?? .expired
    }
    switch event {
    case .markerGone: return .markerGone
    case .expired: return .expired
    case .exited: return await revert()
    }
  }

  private func revert() async -> Outcome {
    for _ in 0..<3 {
      guard markerIsOurs else { return .markerGone }
      if let observed = try? await power.setSleepDisabled(false), observed.confirmedDisabled {
        clearMarker()
        return .reverted
      }
    }
    return .revertFailed
  }
}

public enum ProcessExit {
  /// Returns when the process with this pid and start time has exited, via kqueue
  /// EVFILT_PROC NOTE_EXIT (a dispatch process source). Returns at once if it already has, and
  /// when the task is cancelled.
  public static func wait(pid: Int32, startMicros: Int64) async {
    guard ProcessStartTime.micros(pid: pid) == startMicros else { return }
    let waiter = ExitWaiter()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        waiter.begin(continuation)
        let source = DispatchSource.makeProcessSource(
          identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { waiter.finish() }
        waiter.attach(source)
        source.resume()
        // The process may have exited between the first check and the source going live.
        if ProcessStartTime.micros(pid: pid) != startMicros { waiter.finish() }
      }
    } onCancel: {
      waiter.finish()
    }
  }

  private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var source: (any DispatchSourceProcess)?
    private var finished = false

    func begin(_ continuation: CheckedContinuation<Void, Never>) {
      let resumeNow = lock.withLock {
        if finished { return true }
        self.continuation = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }

    func attach(_ source: any DispatchSourceProcess) {
      let cancelNow = lock.withLock {
        if finished { return true }
        self.source = source
        return false
      }
      if cancelNow { source.cancel() }
    }

    func finish() {
      let (continuation, source) = lock.withLock {
        finished = true
        let held = (self.continuation, self.source)
        self.continuation = nil
        self.source = nil
        return held
      }
      source?.cancel()
      continuation?.resume()
    }
  }
}

/// The hidden `dilated closed-lid-watchdog` subcommand. Not listed in help.
public enum ClosedLidWatchdogCommand {
  public static let name = "closed-lid-watchdog"

  public static func parse(_ arguments: [String]) -> ClosedLidWatchdogLaunch? {
    guard arguments.first == name else { return nil }
    var values: [String: String] = [:]
    var index = 1
    while index + 1 < arguments.count {
      values[arguments[index]] = arguments[index + 1]
      index += 2
    }
    guard index == arguments.count,
      let pid = values["--pid"].flatMap({ Int32($0) }), pid > 0,
      let marker = values["--marker"], marker.hasPrefix("/"),
      let generation = values["--generation"].flatMap({ UUID(uuidString: $0) }),
      let maxSeconds = values["--max-seconds"].flatMap({ Int($0) }), maxSeconds > 0
    else { return nil }
    return ClosedLidWatchdogLaunch(
      pid: pid, marker: URL(fileURLWithPath: marker), generation: generation,
      maxSeconds: maxSeconds)
  }

  public static func arguments(for launch: ClosedLidWatchdogLaunch) -> [String] {
    [
      name, "--pid", String(launch.pid), "--marker", launch.marker.path,
      "--generation", launch.generation.uuidString, "--max-seconds", String(launch.maxSeconds),
    ]
  }

  /// Runs against the real system. Exit status 0 unless sleep couldn't be restored.
  public static func run(_ launch: ClosedLidWatchdogLaunch) async -> Int32 {
    let store = ClosedLidMarkerStore(file: launch.marker)
    guard let marker = store.read(), marker.generation == launch.generation,
      marker.pid == launch.pid
    else { return 0 }
    let watchdog = ClosedLidWatchdog(
      generation: launch.generation, maxLifetime: .seconds(launch.maxSeconds),
      readMarker: { store.read() },
      waitForExit: {
        await ProcessExit.wait(pid: marker.pid, startMicros: marker.processStartMicros)
      },
      power: SerialPowerDriver(runner: SudoPowerRunner()),
      clearMarker: { store.clear(generation: launch.generation) })
    return await watchdog.run() == .revertFailed ? 1 : 0
  }
}
