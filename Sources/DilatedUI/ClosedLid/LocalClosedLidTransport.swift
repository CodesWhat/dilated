import DilatedCore
import Foundation

/// Runs the closed-lid service and governor inside the app instead of a privileged helper.
/// The service is its own actor and a detached loop ticks it, so a hung main thread still lets
/// the lease expire and revert.
@MainActor public final class LocalClosedLidTransport: HelperTransporting {
  public static let buildIdentity = "local-sudo"
  public static let defaultsKey = "DilatedLocalClosedLidTransport"

  public var onDisconnect: (() -> Void)?
  private let service: ClosedLidService
  private let owner = UUID()
  private let ticker: TickLoop
  private let backoff: RetryBackoff

  public init(
    power: any ClosedLidPowerControlling = SerialPowerDriver(runner: SudoPowerRunner()),
    environment: @escaping @Sendable () -> ClosedLidEnvironment = NativeClosedLidPower.environment,
    clock: (@Sendable () -> TimeInterval)? = nil,
    tickInterval: Duration = .seconds(1),
    backoff: RetryBackoff = RetryBackoff(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    let origin = ContinuousClock.now
    let resolved: @Sendable () -> TimeInterval =
      clock ?? {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      }
    let service = ClosedLidService(
      power: power, environment: environment, clock: resolved,
      buildIdentity: Self.buildIdentity)
    self.service = service
    self.backoff = backoff
    ticker = TickLoop(service: service, interval: tickInterval, backoff: backoff, sleep: sleep)
  }

  public func send(_ request: HelperRequest) async throws -> HelperReply {
    backoff.reset()
    await service.start()
    return await service.handle(request, owner: owner)
  }

  public func invalidate() {
    let service = service
    let owner = owner
    Task { await service.disconnected(owner: owner) }
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

private final class TickLoop: Sendable {
  private let task: Task<Void, Never>

  init(
    service: ClosedLidService, interval: Duration, backoff: RetryBackoff,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    task = Task.detached {
      await service.start()
      var delay = interval
      while !Task.isCancelled {
        do { try await sleep(delay) } catch { break }
        await service.tick()
        if await service.isRetryingForPermission {
          delay = backoff.next()
        } else {
          backoff.reset()
          delay = interval
        }
      }
    }
  }

  deinit { task.cancel() }
}

extension ClosedLidController {
  /// Picks the transport from the `DilatedLocalClosedLidTransport` defaults flag. Off by default,
  /// which keeps the privileged helper.
  public static func configured(defaults: UserDefaults = .standard) -> ClosedLidController {
    guard defaults.bool(forKey: LocalClosedLidTransport.defaultsKey) else {
      return ClosedLidController()
    }
    return ClosedLidController(
      transport: LocalClosedLidTransport(),
      expectedBuild: { LocalClosedLidTransport.buildIdentity })
  }
}
