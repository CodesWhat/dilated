import Foundation

public actor ClosedLidService {
  private let power: any ClosedLidPowerControlling
  private let environment: @Sendable () -> ClosedLidEnvironment
  private let clock: @Sendable () -> TimeInterval
  private let buildIdentity: String
  private let heartbeat: (@Sendable () async -> Void)?
  private var governor = ClosedLidGovernor()
  private var phase: HelperPhase = .starting
  private var readback = ClosedLidReadback()
  private var message: String?
  private var started = false
  private var startup: Task<Void, Never>?
  private var resetConfirmed = false
  /// Why the next reset may put the Mac to sleep. Taken when that reset starts and used only
  /// inside it, so a failed or superseded reset never leaves a sleep for a later one.
  private enum SleepIntent { case explicit, closedLidStop }
  private var sleepIntent: SleepIntent?
  private var foreignSleepDisabled = false
  private var revision: UInt64 = 0
  private var permissionFailure = false
  private var operation = UUID()

  public init(
    power: any ClosedLidPowerControlling,
    environment: @escaping @Sendable () -> ClosedLidEnvironment,
    clock: @escaping @Sendable () -> TimeInterval, buildIdentity: String,
    heartbeat: (@Sendable () async -> Void)? = nil
  ) {
    self.heartbeat = heartbeat
    self.power = power
    self.environment = environment
    self.clock = clock
    self.buildIdentity = buildIdentity
  }

  public func start() async {
    if let startup {
      await startup.value
      return
    }
    started = true
    let task = Task { await self.reset() }
    startup = task
    await task.value
  }

  public func handle(_ request: HelperRequest, owner: UUID) async -> HelperReply {
    guard request.protocolVersion == HelperIdentity.protocolVersion else {
      return reply(
        false, code: "protocolMismatch", text: "Dilated needs a matching update.")
    }
    switch request.action {
    case .status:
      let current = operation
      let currentPhase = phase
      let observed = await power.readback()
      if operation == current, phase == currentPhase {
        readback = observed
        settleForeignDisposition()
      }
      return reply(true)
    case .enable:
      guard phase == .off, resetConfirmed, readback.confirmedDisabled else {
        return reply(false, code: "notReady", text: message ?? "The helper isn't ready to enable.")
      }
      guard let policy = request.policy else {
        return reply(false, code: "invalidRequest", text: "A closed-lid safety policy is required.")
      }
      do {
        try governor.begin(owner: owner, policy: policy, environment: environment(), now: clock())
      } catch { return failure(error) }
      return await enable()
    case .heartbeat:
      guard phase == .on, let id = request.leaseID else {
        return reply(
          false, code: "missingLease", text: ClosedLidError.missingLease.localizedDescription)
      }
      do {
        if let stopped = try governor.heartbeat(
          owner: owner, id: id, environment: environment(), now: clock())
        {
          await stop(stopped)
          return reply(false, code: "leaseEnded", text: stopped.reason.localizedDescription)
        }
        await tick()
        guard governor.lease?.id == id, phase == .on, readback.confirmedEnabled else {
          return reply(
            false, code: "leaseEnded", text: "Closed-lid ended. Enable it again to continue.")
        }
        return reply(true)
      } catch { return failure(error) }
    case .disable, .sleep:
      if let lease = governor.lease {
        guard lease.owner == owner else { return failure(ClosedLidError.notLeaseOwner) }
        if let id = request.leaseID, id != lease.id { return failure(ClosedLidError.missingLease) }
      }
      guard phase != .starting, phase != .disabling, phase != .sleeping else {
        return reply(false, code: "busy", text: "The helper is finishing a power operation.")
      }
      let stopped = governor.stop(reason: .disabled, environment: environment())
      if request.action == .sleep {
        sleepIntent = .explicit
      } else if stopped?.requestSleep == true, sleepIntent == nil {
        sleepIntent = .closedLidStop
      }
      await reset()
      return reply(phase == .off, code: phase == .off ? nil : "powerFailure")
    }
  }

  /// True while the service is stuck in `.failed` because sudo refused the power command, so a
  /// caller can slow its retries without giving up.
  public var isRetryingForPermission: Bool { phase == .failed && permissionFailure }

  /// True while the tick has something to do: a lease to guard, or our own restoration of sleep
  /// still unconfirmed. Sleep another app disabled is not ours to restore, so it doesn't count.
  public var needsTicks: Bool {
    if governor.lease != nil { return true }
    switch phase {
    case .starting, .enabling, .on, .disabling, .sleeping, .failed: return true
    case .off: return !foreignSleepDisabled && !readback.confirmedDisabled
    }
  }

  /// True while the service is retrying its own failed restoration or holding off on another
  /// app's sleep-disable, so a caller can push the changing state to its UI.
  public var isRecovering: Bool { phase == .failed || foreignSleepDisabled }

  public var holdsLease: Bool { governor.lease != nil }

  public func snapshot() -> HelperState { state() }

  public func tick() async {
    guard started else { return }
    if governor.lease != nil,
      let stopped = governor.reconcile(environment: environment(), now: clock())
    {
      await stop(stopped)
      return
    }
    if phase == .on, governor.lease != nil { await heartbeat?() }
    guard phase != .enabling, phase != .disabling, phase != .sleeping else { return }
    if phase == .failed {
      await reset()
      return
    }
    let current = operation
    let observed = await power.readback()
    guard operation == current else { return }
    readback = observed
    settleForeignDisposition()
    if phase == .on, governor.lease != nil, !observed.confirmedEnabled {
      if let stopped = governor.reconcile(environment: environment(), now: clock()) {
        await stop(stopped)
      } else {
        _ = await enable()
      }
    } else if phase == .off, !observed.confirmedDisabled || foreignSleepDisabled {
      await reset()
    }
  }

  public func disconnected(owner: UUID) async {
    if let stopped = governor.disconnected(owner: owner, environment: environment()) {
      await stop(stopped)
    }
  }

  /// Another app's sleep-disable that has since cleared leaves nothing of ours to restore, so
  /// the reset counts as confirmed without running any power command.
  private func settleForeignDisposition() {
    guard foreignSleepDisabled, phase == .off, readback.confirmedDisabled else { return }
    foreignSleepDisabled = false
    resetConfirmed = true
    message = nil
  }

  private func enable() async -> HelperReply {
    let current = UUID()
    operation = current
    phase = .enabling
    do {
      let observed = try await power.setSleepDisabled(true)
      guard operation == current else { return reply(false, code: "superseded") }
      readback = observed
      guard observed.confirmedEnabled else { throw ClosedLidPowerError.readbackMismatch }
      if let stopped = governor.reconcile(environment: environment(), now: clock()) {
        await stop(stopped)
        return reply(false, code: "leaseEnded", text: stopped.reason.localizedDescription)
      }
      phase = .on
      message = nil
      return reply(true)
    } catch {
      guard operation == current else { return reply(false, code: "superseded") }
      let failureText = error.localizedDescription
      let revertedByWatchdog = error as? ClosedLidSessionError == .revertedWhileUnresponsive
      let stopped = governor.stop(
        reason: revertedByWatchdog ? .leaseExpired : .disabled, environment: environment())
      if stopped?.requestSleep == true, sleepIntent == nil { sleepIntent = .closedLidStop }
      await reset()
      return reply(false, code: "powerFailure", text: failureText)
    }
  }

  private func stop(_ stopped: ClosedLidStop) async {
    if stopped.requestSleep, sleepIntent == nil { sleepIntent = .closedLidStop }
    await reset()
  }

  private func reset() async {
    let current = UUID()
    operation = current
    phase = .disabling
    resetConfirmed = false
    foreignSleepDisabled = false
    let intent = sleepIntent
    sleepIntent = nil
    do {
      let observed = try await power.setSleepDisabled(false)
      guard operation == current else { return }
      readback = observed
      guard observed.confirmedDisabled else {
        guard await power.foreignSleepDisabled() else { throw ClosedLidPowerError.readbackMismatch }
        guard operation == current else { return }
        foreignSleepDisabled = true
        phase = .off
        message = "Another app has turned sleep off, so Dilated left it alone."
        permissionFailure = false
        return
      }
      resetConfirmed = true
      // An automatic stop sleeps only if the lid is closed right now, not when it was stopped.
      if let intent, intent == .explicit || environment().lidClosed == true {
        phase = .sleeping
        try await power.sleep()
        guard operation == current else { return }
      }
      phase = .off
      message = nil
      permissionFailure = false
    } catch {
      guard operation == current else { return }
      readback = await power.readback()
      guard operation == current else { return }
      phase = .failed
      message = error.localizedDescription
      if case ClosedLidPowerError.permissionUnavailable = error {
        permissionFailure = true
      } else {
        permissionFailure = false
      }
    }
  }

  private func reply(_ ok: Bool, code: String? = nil, text: String? = nil) -> HelperReply {
    let state = state()
    return HelperReply(ok: ok, code: code, message: text ?? message, state: state)
  }

  private func state() -> HelperState {
    let remaining = governor.lease.map { max(0, $0.expiry - clock()) }
    revision += 1
    return HelperState(
      protocolVersion: HelperIdentity.protocolVersion, buildIdentity: buildIdentity,
      generation: governor.generation,
      ready: resetConfirmed
        && ((phase == .off && readback.confirmedDisabled)
          || (phase == .on && readback.confirmedEnabled)),
      phase: phase,
      enabled: phase == .on && governor.lease != nil && readback.confirmedEnabled,
      leaseID: governor.lease?.id, leaseRemainingSeconds: remaining, readback: readback,
      environment: environment(), stopReason: governor.lastStop, message: message,
      foreignSleepDisabled: foreignSleepDisabled, sequence: revision)
  }

  private func failure(_ error: any Error) -> HelperReply {
    let code: String
    switch error {
    case ClosedLidError.missingLease: code = "missingLease"
    case ClosedLidError.notLeaseOwner: code = "notLeaseOwner"
    case ClosedLidError.alreadyActive: code = "alreadyActive"
    case ClosedLidError.invalidPolicy: code = "invalidPolicy"
    default: code = "unsafe"
    }
    return reply(false, code: code, text: error.localizedDescription)
  }
}
