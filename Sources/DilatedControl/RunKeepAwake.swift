import DilatedCore
import Foundation

/// Keeps `dilated run` awake for as long as its child runs. The local assertion is an indefinite,
/// local-only hold, so a wall-clock gap (sleep, SIGSTOP) can't expire it. `refresh()` never throws:
/// every failure is reported once, the assertions are released, and the caller keeps supervising the
/// child until it really exits.
@MainActor public final class RunKeepAwake {
  public struct Environment {
    public var now: () -> Date
    public var readPower: () -> PowerState
    public var send: (ControlRequest) throws -> ControlResponse
    public var loadSnapshot: () throws -> EngineSnapshot
    public var report: (String) -> Void
    public init(
      now: @escaping () -> Date, readPower: @escaping () -> PowerState,
      send: @escaping (ControlRequest) throws -> ControlResponse,
      loadSnapshot: @escaping () throws -> EngineSnapshot, report: @escaping (String) -> Void
    ) {
      self.now = now
      self.readPower = readPower
      self.send = send
      self.loadSnapshot = loadSnapshot
      self.report = report
    }
  }

  public static let leaseSeconds: TimeInterval = 30

  public private(set) var keepingAwake = true
  public private(set) var managedID: UUID?
  private var local: WakeEngine
  private let assertions: any AssertionControlling
  private let environment: Environment
  private let label: String
  private let displayAwake: Bool
  private let lowPowerOverride: Bool
  private let closedLid: Bool

  /// `local` must already hold the indefinite local-only hold from `WakeEngine.start`.
  public init(
    local: WakeEngine, managedID: UUID?, label: String, displayAwake: Bool,
    lowPowerOverride: Bool, closedLid: Bool = false, assertions: any AssertionControlling,
    environment: Environment
  ) {
    self.local = local
    self.managedID = managedID
    self.label = label
    self.displayAwake = displayAwake
    self.lowPowerOverride = lowPowerOverride
    self.closedLid = closedLid
    self.assertions = assertions
    self.environment = environment
  }

  public func refresh() {
    guard keepingAwake else { return }
    local.updatePower(environment.readPower(), now: environment.now())
    if local.holds.isEmpty {
      end(local.attention ?? "a power safety limit was reached")
      return
    }
    if let reason = renewRemote() {
      end(reason)
      return
    }
    do {
      try assertions.synchronize(holds: local.holds, now: environment.now())
    } catch {
      end("couldn't refresh the sleep assertions: \(error.localizedDescription)")
    }
  }

  /// Returns the reason keep-awake must end, or nil to carry on.
  private func renewRemote() -> String? {
    do {
      var response: ControlResponse
      if let id = managedID {
        response = try environment.send(
          ControlRequest(action: .renew, id: id, duration: Self.leaseSeconds))
        // A hold the user released stays released. Otherwise the app may have expired its lease
        // across a long gap or restarted, so re-register; a Stop pauses automation, so a stopped
        // run is refused here instead of silently resurrected.
        if !response.ok {
          if response.released == true { return "the hold was released" }
          response = try register()
        }
      } else {
        response = try register()
      }
      guard response.ok else { return response.message ?? "the hold ended" }
      managedID = response.id ?? managedID
    } catch {
      do {
        let snapshot = try environment.loadSnapshot()
        if snapshot.automationPaused { return "automation is paused" }
        // A single-hold release doesn't pause automation, so check for it by id. With no matching
        // recent release, stay awake offline.
        if let managedID,
          snapshot.released.contains(where: {
            $0.id == managedID
              && environment.now().timeIntervalSince($0.at) < WakeEngine.releasedMaxAge
          })
        {
          return "the hold was released"
        }
      } catch {
        return "couldn't read Dilated's state: \(error.localizedDescription)"
      }
    }
    return nil
  }

  private func register() throws -> ControlResponse {
    try environment.send(
      ControlRequest(
        action: .runner, label: label, duration: Self.leaseSeconds, displayAwake: displayAwake,
        lowPowerOverride: lowPowerOverride, closedLid: closedLid))
  }

  private func end(_ reason: String) {
    assertions.releaseAll()
    keepingAwake = false
    environment.report("Keep-awake ended: \(reason). The command is still running.")
  }
}
