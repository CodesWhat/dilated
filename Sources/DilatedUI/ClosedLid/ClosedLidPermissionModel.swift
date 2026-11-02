import DilatedCore
import Observation

/// What Settings and the control socket show for closed-lid permission, and the actions behind
/// the buttons. Every side effect goes through the injected `ClosedLidPermission` and callbacks.
@MainActor @Observable public final class ClosedLidPermissionModel {
  public private(set) var state: ClosedLidPermissionState?
  public private(set) var busy = false
  public private(set) var lastError: String?
  public private(set) var recovery = ClosedLidSessionGuard.Recovery.notChecked
  @ObservationIgnored private let permission: ClosedLidPermission
  @ObservationIgnored private let readRecovery:
    @MainActor () async -> ClosedLidSessionGuard.Recovery
  @ObservationIgnored private let acknowledgeRestore: @MainActor () async -> Bool

  public init(
    permission: ClosedLidPermission = ClosedLidPermission(),
    recovery: @escaping @MainActor () async -> ClosedLidSessionGuard.Recovery = { .notChecked },
    acknowledgeRestore: @escaping @MainActor () async -> Bool = { false }
  ) {
    self.permission = permission
    readRecovery = recovery
    self.acknowledgeRestore = acknowledgeRestore
  }

  public enum Result: Equatable, Sendable { case done, cancelled, failed }

  public func refresh() async {
    state = await permission.state()
    recovery = await readRecovery()
  }

  /// Cancelling the admin prompt is a no-op: nothing changes and no error shows.
  @discardableResult public func install() async -> Result {
    await run { await permission.install() }
  }
  @discardableResult public func remove() async -> Result {
    await run { await permission.remove() }
  }

  /// Runs the admin-prompt `pmset -a disablesleep 0`.
  @discardableResult public func restoreNormalSleep() async -> Result {
    guard !busy else { return .failed }
    busy = true
    lastError = nil
    defer { busy = false }
    switch await permission.restoreNormalSleep() {
    case .cancelled:
      return .cancelled
    case .failed(let message):
      lastError = message
      return .failed
    case .succeeded:
      guard await acknowledgeRestore() else {
        lastError = "macOS hasn't confirmed normal sleep yet. Try again."
        await refresh()
        return .failed
      }
      await refresh()
      return .done
    }
  }

  private func run(_ action: () async -> ClosedLidPermissionOutcome) async -> Result {
    guard !busy else { return .failed }
    busy = true
    lastError = nil
    defer { busy = false }
    switch await action() {
    case .cancelled:
      await refresh()
      return .cancelled
    case .completed(let result):
      state = result
      recovery = await readRecovery()
      return .done
    case .failed(let message, let result):
      state = result
      lastError = message
      recovery = await readRecovery()
      return .failed
    }
  }

  public var title: String {
    switch state {
    case nil: "Checking closed-lid permission"
    case .ready: "Closed-lid permission is set up"
    case .notInstalled: "Closed-lid permission isn't set up"
    case .needsRepair: "Closed-lid permission needs repair"
    case .blocked: "macOS isn't honoring the permission"
    case .notAdmin: "Closed-lid needs an administrator account"
    }
  }

  public var detail: String {
    switch state {
    case nil: "One moment."
    case .ready:
      "Dilated can turn sleep off for closed-lid holds. Regular awake holds never need it."
    case .notInstalled:
      "Set up closed-lid permission to keep working with the lid closed. You'll enter your password once. Regular awake holds work without it."
    case .needsRepair:
      "The permission file isn't what Dilated wrote. Repair it, or remove it."
    case .blocked:
      "The permission file is in place, but sudo isn't honoring the rule. Repair it, or check that /etc/sudoers includes /etc/sudoers.d."
    case .notAdmin:
      "Closed-lid permission only works for administrators. Switch to an administrator account to use it."
    }
  }

  public var setUpTitle: String? {
    switch state {
    case .notInstalled: "Set Up"
    case .needsRepair, .blocked: "Repair"
    default: nil
    }
  }

  public var canRemove: Bool {
    switch state {
    case .ready, .needsRepair, .blocked: true
    default: false
    }
  }

  /// Plain words for the CLI and control socket.
  public var summary: String {
    switch state {
    case .ready: "Closed-lid permission is set up."
    case .notInstalled: "Closed-lid permission isn't set up."
    case .needsRepair: "Closed-lid permission needs repair."
    case .blocked: "Closed-lid permission is in place, but macOS isn't honoring it."
    case .notAdmin: "Closed-lid needs an administrator account."
    case nil: "Closed-lid permission hasn't been checked."
    }
  }

  public var recoveryTitle: String? {
    switch recovery {
    case .foreignSleepDisabled: "Another app has turned off sleep"
    case .failed: "Dilated couldn't restore normal sleep"
    default: nil
    }
  }

  public var recoveryDetail: String? {
    switch recovery {
    case .foreignSleepDisabled: "Dilated left it alone because it didn't start it."
    case .failed(let reason): reason
    default: nil
    }
  }

  public var canRestoreNormalSleep: Bool {
    if case .failed = recovery { return true }
    return false
  }
}
