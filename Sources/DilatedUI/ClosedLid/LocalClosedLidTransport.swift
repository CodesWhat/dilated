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

  public init(
    power: any ClosedLidPowerControlling = SerialPowerDriver(runner: SudoPowerRunner()),
    environment: @escaping @Sendable () -> ClosedLidEnvironment = NativeClosedLidPower.environment,
    clock: (@Sendable () -> TimeInterval)? = nil,
    tickInterval: Duration = .seconds(1)
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
    ticker = TickLoop(service: service, interval: tickInterval)
  }

  public func send(_ request: HelperRequest) async throws -> HelperReply {
    await service.start()
    return await service.handle(request, owner: owner)
  }

  public func invalidate() {
    let service = service
    let owner = owner
    Task { await service.disconnected(owner: owner) }
  }
}

private final class TickLoop: Sendable {
  private let task: Task<Void, Never>

  init(service: ClosedLidService, interval: Duration) {
    task = Task.detached {
      await service.start()
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { break }
        await service.tick()
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
