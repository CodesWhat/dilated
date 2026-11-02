import Darwin
import Foundation

/// Restores sleep after the app dies. Runs in a detached `dilated` process; this is the logic,
/// with every dependency injected so it can be tested without sudo or a real crash.
public struct ClosedLidWatchdog: Sendable {
  public enum Outcome: Equatable, Sendable {
    case reverted
    /// The wait was cancelled while a revert was still failing. The marker stays for the relaunch revert.
    case revertFailed
    /// The session ended normally, or a newer one replaced it.
    case markerGone
  }

  private enum Event: Sendable { case exited, markerGone }

  /// First retry delay after a failed revert. It doubles up to `maxRevertBackoff`.
  public static let initialRevertBackoff = Duration.seconds(5)
  public static let maxRevertBackoff = Duration.seconds(300)

  public static func revertBackoff(attempt: Int) -> Duration {
    var delay = initialRevertBackoff
    for _ in 0..<max(attempt, 0) {
      delay = min(delay * 2, maxRevertBackoff)
    }
    return delay
  }

  private let generation: UUID
  private let pollInterval: Duration
  private let readMarker: @Sendable () -> ClosedLidSessionMarker?
  private let waitForExit: @Sendable () async -> Void
  private let power: any ClosedLidPowerControlling
  private let clearMarker: @Sendable () -> Void
  private let acquireLock: @Sendable () async -> (@Sendable () -> Void)?
  private let sleep: @Sendable (Duration) async throws -> Void

  /// `acquireLock` returns a release closure, or nil when the lock couldn't be taken in time.
  public init(
    generation: UUID, pollInterval: Duration = .seconds(10),
    readMarker: @escaping @Sendable () -> ClosedLidSessionMarker?,
    waitForExit: @escaping @Sendable () async -> Void,
    power: any ClosedLidPowerControlling,
    clearMarker: @escaping @Sendable () -> Void,
    acquireLock: @escaping @Sendable () async -> (@Sendable () -> Void)? = { {} },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.generation = generation
    self.pollInterval = pollInterval
    self.readMarker = readMarker
    self.waitForExit = waitForExit
    self.power = power
    self.clearMarker = clearMarker
    self.acquireLock = acquireLock
    self.sleep = sleep
  }

  /// Ours means the same generation and a usable start time. A zero start time can't identify
  /// the app, so it's never acted on.
  private var markerIsOurs: Bool {
    guard let marker = readMarker() else { return false }
    return marker.generation == generation && marker.processStartMicros > 0
  }

  /// Waits as long as the marker is ours and the app is alive. There is no lifetime cap: an AC
  /// session can run indefinitely, and the poll ends the watchdog once the marker goes away.
  public func run() async -> Outcome {
    guard markerIsOurs else { return .markerGone }
    // Two plain tasks race through a stream; whichever reports first decides the outcome.
    let (stream, events) = AsyncStream.makeStream(of: Event.self)
    let exit = Task {
      await waitForExit()
      if !Task.isCancelled { events.yield(.exited) }
    }
    let poll = Task {
      // A plain do/catch, not `(try? await sleep(...)) != nil`: Swift on macOS 26 aborts in
      // swift_task_dealloc on that form inside a Task closure (CI crash report, 2026-11-02).
      while true {
        do { try await sleep(pollInterval) } catch { return }
        if !markerIsOurs {
          events.yield(.markerGone)
          return
        }
      }
    }
    let event: Event? = await withTaskCancellationHandler {
      var first: Event?
      for await next in stream {
        first = next
        break
      }
      return first
    } onCancel: {
      exit.cancel()
      poll.cancel()
      events.finish()
    }
    exit.cancel()
    poll.cancel()
    events.finish()
    await exit.value
    await poll.value
    switch event {
    case .markerGone, nil: return .markerGone
    case .exited: return await revert()
    }
  }

  /// Retries with backoff for as long as the marker is still ours. Each attempt holds the lock,
  /// re-checks the marker, reverts, confirms the readback, then deletes the marker.
  private func revert() async -> Outcome {
    var attempt = 0
    while true {
      guard markerIsOurs else { return .markerGone }
      if let release = await acquireLock() {
        defer { release() }
        guard markerIsOurs else { return .markerGone }
        if let observed = try? await power.setSleepDisabled(false), observed.confirmedDisabled {
          clearMarker()
          return .reverted
        }
      }
      do { try await sleep(Self.revertBackoff(attempt: attempt)) } catch { return .revertFailed }
      attempt += 1
    }
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
      let generation = values["--generation"].flatMap({ UUID(uuidString: $0) })
    else { return nil }
    return ClosedLidWatchdogLaunch(
      pid: pid, marker: URL(fileURLWithPath: marker), generation: generation)
  }

  public static func arguments(for launch: ClosedLidWatchdogLaunch) -> [String] {
    [
      name, "--pid", String(launch.pid), "--marker", launch.marker.path,
      "--generation", launch.generation.uuidString,
    ]
  }

  /// Runs against the real system. Exit status 0 unless sleep couldn't be restored.
  public static func run(_ launch: ClosedLidWatchdogLaunch) async -> Int32 {
    let store = ClosedLidMarkerStore(file: launch.marker)
    guard let marker = store.read(), marker.generation == launch.generation,
      marker.pid == launch.pid, marker.processStartMicros > 0
    else { return 0 }
    let watchdog = ClosedLidWatchdog(
      generation: launch.generation,
      readMarker: { store.read() },
      waitForExit: {
        await ProcessExit.wait(pid: marker.pid, startMicros: marker.processStartMicros)
      },
      power: SerialPowerDriver(runner: SudoPowerRunner()),
      clearMarker: { store.clear(generation: launch.generation) },
      acquireLock: {
        guard let lock = try? await store.acquireLock() else { return nil }
        return { lock.release() }
      })
    return await watchdog.run() == .revertFailed ? 1 : 0
  }
}
