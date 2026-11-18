import DilatedControl
import DilatedCore
import Foundation

/// Runs the closed-lid service and governor inside the app.
/// The service is its own actor and a detached loop ticks it, so a hung main thread still lets
/// the lease expire and revert.
@MainActor public final class LocalClosedLidTransport: HelperTransporting {
  public static let buildIdentity = "local-sudo"

  /// The direct build runs sudo itself; the sandboxed Mac App Store build runs the script the
  /// Closed-Lid Setup companion installed.
  public static var powerRunner: any PowerCommandRunning {
    #if MAS_CHANNEL
      UserScriptPowerRunner()
    #else
      SudoPowerRunner()
    #endif
  }

  public var onDisconnect: (() -> Void)?
  /// Receives the service's state while it recovers on its own, so a UI that asked nothing still
  /// sees a failed restoration clear.
  public var onSnapshot: ((HelperState) -> Void)?
  private let service: ClosedLidService
  private let owner = UUID()
  private var ticker: TickLoop?
  private let tickInterval: Duration
  private let tickSleep: @Sendable (Duration) async throws -> Void
  private let wake = TickWake()
  private let seen = SeenState()
  private let mailbox = SnapshotMailbox()
  private let backoff: RetryBackoff
  private let sessionGuard: ClosedLidSessionGuard?

  public init(
    sessionGuard: ClosedLidSessionGuard? = nil,
    power: any ClosedLidPowerControlling = SerialPowerDriver(
      runner: LocalClosedLidTransport.powerRunner),
    environment: @escaping @Sendable () -> ClosedLidEnvironment = NativeClosedLidPower.environment,
    clock: (@Sendable () -> TimeInterval)? = nil,
    tickInterval: Duration = .seconds(1),
    backoff: RetryBackoff = RetryBackoff(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    autostart: Bool = true
  ) {
    let origin = ContinuousClock.now
    let resolved: @Sendable () -> TimeInterval =
      clock ?? {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      }
    let beat: (@Sendable () async -> Void)? =
      if let sessionGuard { { await sessionGuard.beat() } } else { nil }
    let service = ClosedLidService(
      power: power, environment: environment, clock: resolved,
      buildIdentity: Self.buildIdentity,
      heartbeat: beat)
    self.service = service
    self.backoff = backoff
    self.sessionGuard = sessionGuard
    self.tickInterval = tickInterval
    tickSleep = sleep
    if autostart { startTicking() }
  }

  /// Starts the service, which reverts a dead session's sleep-disable. The 1s tick it starts
  /// sleeps whenever there's no lease and nothing of ours to restore, and wakes on a request.
  /// Idempotent. The app calls it at launch; a request starts it too.
  public func startTicking() {
    guard ticker == nil else { return }
    ticker = TickLoop(
      service: service, interval: tickInterval, backoff: backoff, sleep: tickSleep, wake: wake,
      seen: seen
    ) { [weak self] state in
      // Never awaited: a blocked main actor must not slow the safety loop.
      guard let self, self.mailbox.put(state) else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        while let latest = self.mailbox.take() { self.onSnapshot?(latest) }
      }
    }
  }

  public func send(_ request: HelperRequest) async throws -> HelperReply {
    startTicking()
    backoff.reset()
    wake.signal()
    await service.start()
    let reply = await service.handle(request, owner: owner)
    seen.record(reply.state)
    wake.signal()
    return reply
  }

  /// What the launch-time check found. Slice 4's UI reads this to show a failed revert or a
  /// sleep-disable that something else owns.
  public func recovery() async -> ClosedLidSessionGuard.Recovery {
    await sessionGuard?.recovery ?? .notChecked
  }

  /// Tells the session guard that sleep was restored by hand. False when macOS doesn't confirm it.
  public func acknowledgeRestore() async -> Bool {
    let restored = await sessionGuard?.acknowledgeManualRestore() ?? false
    wake.signal()
    return restored
  }

  public func invalidate() {
    let service = service
    let owner = owner
    let wake = wake
    Task {
      await service.disconnected(owner: owner)
      wake.signal()
    }
  }
}

/// Retry delay while sudo keeps refusing: doubles from `initial` up to `cap`, and starts over on
/// `reset()`. The service keeps retrying and stays failed; only the cadence slows.
public final class RetryBackoff: @unchecked Sendable {
  private let initial: Duration
  private let cap: Duration
  private let lock = NSLock()
  private var current: Duration?

  public init(initial: Duration = .seconds(1), cap: Duration = .seconds(30)) {
    self.initial = initial
    self.cap = cap
  }

  public func next() -> Duration {
    lock.withLock {
      let delay = current.map { min($0 * 2, cap) } ?? min(initial, cap)
      current = delay
      return delay
    }
  }

  public func reset() { lock.withLock { current = nil } }
}

/// Wakes a sleeping `TickLoop`. A signal sent while the loop is awake is kept until its next wait.
final class TickWake: Sendable {
  fileprivate let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func signal() { continuation.yield(()) }
  func finish() { continuation.finish() }
}

/// The newest pushed state waiting for the main actor. Pushes that arrive before it drains
/// replace each other, so a slow main actor sees the latest state once.
final class SnapshotMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: HelperState?
  private var draining = false

  /// True when the caller must start a drain.
  func put(_ state: HelperState) -> Bool {
    lock.withLock {
      latest = state
      guard !draining else { return false }
      draining = true
      return true
    }
  }

  func take() -> HelperState? {
    lock.withLock {
      defer { latest = nil }
      if latest == nil { draining = false }
      return latest
    }
  }
}

/// The last service state the controller is known to hold, from a reply or a push.
final class SeenState: @unchecked Sendable {
  private let lock = NSLock()
  private var last: HelperState?

  func record(_ state: HelperState?) { lock.withLock { last = state } }

  /// Whether `state` is worth pushing: it differs from what the controller holds (leaving out the
  /// readings that change every second) and either side was a failed restore or a foreign disable.
  func shouldPush(_ state: HelperState) -> Bool {
    lock.withLock {
      guard let last else { return state.phase == .failed || state.foreignSleepDisabled }
      var a = last
      let b = state
      a.environment = b.environment
      a.leaseRemainingSeconds = b.leaseRemainingSeconds
      guard a != b else { return false }
      return Self.needsAttention(last) || Self.needsAttention(state)
    }
  }

  /// A failed restore, a foreign disable, or sleep still disabled. Leaving any of these is a
  /// change the controller has to hear about, however the last state it saw got there.
  private static func needsAttention(_ state: HelperState) -> Bool {
    state.phase == .failed || state.foreignSleepDisabled || !state.readback.confirmedDisabled
  }
}

private final class TickLoop: Sendable {
  private let task: Task<Void, Never>
  private let wake: TickWake

  init(
    service: ClosedLidService, interval: Duration, backoff: RetryBackoff,
    sleep: @escaping @Sendable (Duration) async throws -> Void, wake: TickWake,
    seen: SeenState, deliver: @escaping @Sendable (HelperState) -> Void
  ) {
    self.wake = wake
    task = Task.detached {
      await service.start()
      var waiting = wake.stream.makeAsyncIterator()
      var delay = interval
      // Pushes the service's state to the controller when it changed on its own during recovery.
      func publish() async {
        guard await !service.holdsLease else { return }
        let state = await service.snapshot()
        guard seen.shouldPush(state) else { return }
        seen.record(state)
        deliver(state)
      }
      while !Task.isCancelled {
        await publish()
        // With no lease and nothing of ours to restore there's nothing to tick for.
        guard await service.needsTicks else {
          backoff.reset()
          delay = interval
          guard await waiting.next() != nil else { break }
          continue
        }
        do { try await sleep(delay) } catch { break }
        await service.tick()
        if await service.isRecovering {
          delay = backoff.next()
        } else {
          backoff.reset()
          delay = interval
        }
      }
    }
  }

  deinit {
    task.cancel()
    wake.finish()
  }
}

extension ClosedLidController {
  /// The app's closed-lid controller: the in-process service behind the sudo rule, with the
  /// session marker and watchdog.
  public static func configured(
    stateDirectory: URL = SocketEndpoint.current.stateDirectory
  ) -> ClosedLidController {
    #if MAS_CHANNEL
      // No watchdog process in the sandboxed build. The script's LaunchAgent reverts after a
      // crash or hang; the in-app lease and the relaunch revert still run.
      let beat = ClosedLidScriptBeat()
      let session = ClosedLidSessionGuard(
        power: SerialPowerDriver(runner: LocalClosedLidTransport.powerRunner),
        store: ClosedLidMarkerStore(directory: stateDirectory),
        heartbeatInterval: ClosedLidSessionGuard.scriptHeartbeatInterval,
        scriptBeat: { beat.send() })
    #else
      let session = ClosedLidSessionGuard(
        power: SerialPowerDriver(runner: SudoPowerRunner()),
        store: ClosedLidMarkerStore(directory: stateDirectory),
        launchWatchdog: ClosedLidWatchdogSpawner.launcher())
    #endif
    return ClosedLidController(
      transport: LocalClosedLidTransport(sessionGuard: session, power: session, autostart: false),
      expectedBuild: { LocalClosedLidTransport.buildIdentity })
  }
}
