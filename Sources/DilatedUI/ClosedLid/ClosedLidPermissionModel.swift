import DilatedCore
import Observation

/// What Settings and the control socket show for closed-lid permission, and the actions behind
/// the buttons. Every side effect goes through the injected `ClosedLidPermission` and callbacks.
@MainActor @Observable public final class ClosedLidPermissionModel {
  public private(set) var state: ClosedLidPermissionState?
  public private(set) var busy = false
  public private(set) var lastError: String?
  public private(set) var recovery = ClosedLidSessionGuard.Recovery.notChecked
  /// What the Mac App Store build's `probe` found. Always nil in the direct build.
  public private(set) var scriptState: ClosedLidScriptState?
  @ObservationIgnored private let permission: ClosedLidPermission
  @ObservationIgnored private let scriptPermission: ClosedLidScriptPermission
  @ObservationIgnored private let readRecovery:
    @MainActor () async -> ClosedLidSessionGuard.Recovery
  @ObservationIgnored private let acknowledgeRestore: @MainActor () async -> Bool

  public init(
    permission: ClosedLidPermission = ClosedLidPermission(),
    scriptPermission: ClosedLidScriptPermission = ClosedLidScriptPermission(),
    recovery: @escaping @MainActor () async -> ClosedLidSessionGuard.Recovery = { .notChecked },
    acknowledgeRestore: @escaping @MainActor () async -> Bool = { false }
  ) {
    self.permission = permission
    self.scriptPermission = scriptPermission
    readRecovery = recovery
    self.acknowledgeRestore = acknowledgeRestore
  }

  public enum Result: Equatable, Sendable { case done, cancelled, failed }

  public func refresh() async {
    #if MAS_CHANNEL
      let script = await scriptPermission.state()
      scriptState = script
      state = script == .ready ? .ready : .notInstalled
    #else
      state = await permission.state()
    #endif
    recovery = await readRecovery()
  }

  #if MAS_CHANNEL
    static let setupMessage = "The app can't install the rule itself. Use Dilated Closed-Lid Setup."

    /// The sandboxed build never installs or removes the rule; the companion does.
    private func refuseSetup() -> Result {
      lastError = Self.setupMessage
      return .failed
    }
  #endif

  /// Cancelling the admin prompt is a no-op: nothing changes and no error shows.
  @discardableResult public func install() async -> Result {
    #if MAS_CHANNEL
      return refuseSetup()
    #else
      return await run { await permission.install() }
    #endif
  }
  @discardableResult public func remove() async -> Result {
    #if MAS_CHANNEL
      return refuseSetup()
    #else
      return await run { await permission.remove() }
    #endif
  }

  /// Runs the admin-prompt `pmset -a disablesleep 0`.
  @discardableResult public func restoreNormalSleep() async -> Result {
    guard !busy else { return .failed }
    busy = true
    lastError = nil
    defer { busy = false }
    switch await restoreOutcome() {
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

  private func restoreOutcome() async -> PrivilegedScriptOutcome {
    #if MAS_CHANNEL
      // The sandboxed build can't show an admin prompt; the installed script does the revert.
      do {
        try await UserScriptPowerRunner().run(.setSleepDisabled(false))
        return .succeeded
      } catch {
        return .failed(error.localizedDescription)
      }
    #else
      return await permission.restoreNormalSleep()
    #endif
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

  #if MAS_CHANNEL
    /// Plain copy for the two states the companion fixes.
    private var scriptCopy: String? {
      switch scriptState {
      case .scriptMissing: "Closed-lid mode needs the Dilated Closed-Lid Setup companion."
      case .ruleMissing: "Closed-lid permission isn't set up. Run Dilated Closed-Lid Setup again."
      case .ready, nil: nil
      }
    }
  #endif

  public var title: String {
    switch state {
    case nil: "Checking closed-lid permission"
    case .ready: "Closed-lid permission is set up"
    case .notInstalled: "Closed-lid permission isn't set up"
    case .needsRepair: "Closed-lid permission needs repair"
    case .blocked: "macOS isn't honoring the permission"
    case .notAdmin: "Closed-lid needs an administrator account"
    case .allowedByOtherRule: "Another app's sudo rule allows closed-lid"
    }
  }

  public var detail: String {
    #if MAS_CHANNEL
      if let scriptCopy { return scriptCopy }
    #endif
    return switch state {
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
    case .allowedByOtherRule:
      "Another app's sudo rule already allows this, so closed-lid works now. Set Up adds Dilated's own rule so it doesn't depend on that app."
    }
  }

  public var setUpTitle: String? {
    #if MAS_CHANNEL
      return nil
    #else
      switch state {
      case .notInstalled, .allowedByOtherRule: "Set Up"
      case .needsRepair, .blocked: "Repair"
      default: nil
      }
    #endif
  }

  public var canRemove: Bool {
    #if MAS_CHANNEL
      return false
    #else
      switch state {
      case .ready, .needsRepair, .blocked: true
      default: false
      }
    #endif
  }

  /// Plain words for the CLI and control socket.
  public var summary: String {
    #if MAS_CHANNEL
      if let scriptCopy { return scriptCopy }
    #endif
    return switch state {
    case .ready: "Closed-lid permission is set up."
    case .notInstalled: "Closed-lid permission isn't set up."
    case .needsRepair: "Closed-lid permission needs repair."
    case .blocked: "Closed-lid permission is in place, but macOS isn't honoring it."
    case .notAdmin: "Closed-lid needs an administrator account."
    case .allowedByOtherRule: "Closed-lid works through another app's sudo rule."
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
