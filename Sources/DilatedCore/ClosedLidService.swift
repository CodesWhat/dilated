import Foundation

public actor ClosedLidService {
  private let power: any ClosedLidPowerControlling
  private let environment: @Sendable () -> ClosedLidEnvironment
  private let clock: @Sendable () -> TimeInterval
  private let buildIdentity: String
  private var governor = ClosedLidGovernor()
  private var phase: HelperPhase = .starting
  private var readback = ClosedLidReadback()
  private var message: String?
  private var started = false
  private var resetConfirmed = false
  private var pendingSleep = false
  private var operation = UUID()

  public init(
    power: any ClosedLidPowerControlling,
    environment: @escaping @Sendable () -> ClosedLidEnvironment,
    clock: @escaping @Sendable () -> TimeInterval, buildIdentity: String
  ) {
    self.power = power
    self.environment = environment
    self.clock = clock
    self.buildIdentity = buildIdentity
  }

  public func start() async {
    guard !started else { return }
    started = true
    await reset()
  }

  public func handlePayload(_ payload: Data, owner: UUID) async -> Data {
    let response: HelperReply
    if payload.count <= HelperIdentity.maximumMessageBytes,
      let request = try? JSONDecoder().decode(HelperRequest.self, from: payload)
    {
      response = await handle(request, owner: owner)
    } else {
      response = reply(false, code: "invalidRequest", text: "Invalid helper request.")
    }
    return (try? JSONEncoder().encode(response))
      ?? Data("{\"ok\":false,\"code\":\"encodingFailure\"}".utf8)
  }

  public func handle(_ request: HelperRequest, owner: UUID) async -> HelperReply {
    guard request.protocolVersion == HelperIdentity.protocolVersion else {
      return reply(
        false, code: "protocolMismatch", text: "The app and helper need matching updates.")
    }
    switch request.action {
    case .status:
      let current = operation
      let currentPhase = phase
      let observed = await power.readback()
      if operation == current, phase == currentPhase { readback = observed }
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
      pendingSleep = pendingSleep || request.action == .sleep || stopped?.requestSleep == true
      await reset()
      return reply(phase == .off, code: phase == .off ? nil : "powerFailure")
    }
  }

  public func tick() async {
    guard started else { return }
    if let stopped = governor.reconcile(environment: environment(), now: clock()) {
      await stop(stopped)
      return
    }
    guard phase != .enabling, phase != .disabling, phase != .sleeping else { return }
    if phase == .failed {
      await reset()
      return
    }
    let current = operation
    let observed = await power.readback()
    guard operation == current else { return }
    readback = observed
    if phase == .on, governor.lease != nil, !observed.confirmedEnabled {
      if let stopped = governor.reconcile(environment: environment(), now: clock()) {
        await stop(stopped)
      } else {
        _ = await enable()
      }
    } else if phase == .off, !observed.confirmedDisabled {
      await reset()
    }
  }

  public func disconnected(owner: UUID) async {
    if let stopped = governor.disconnected(owner: owner, environment: environment()) {
      await stop(stopped)
    }
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
      let stopped = governor.stop(reason: .disabled, environment: environment())
      pendingSleep = pendingSleep || stopped?.requestSleep == true
      await reset()
      return reply(false, code: "powerFailure", text: failureText)
    }
  }

  private func stop(_ stopped: ClosedLidStop) async {
    pendingSleep = pendingSleep || stopped.requestSleep
    await reset()
  }

  private func reset() async {
    let current = UUID()
    operation = current
    phase = .disabling
    resetConfirmed = false
    do {
      let observed = try await power.setSleepDisabled(false)
      guard operation == current else { return }
      readback = observed
      guard observed.confirmedDisabled else { throw ClosedLidPowerError.readbackMismatch }
      resetConfirmed = true
      if pendingSleep {
        phase = .sleeping
        try await power.sleep()
        guard operation == current else { return }
        pendingSleep = false
      }
      phase = .off
      message = nil
    } catch {
      guard operation == current else { return }
      readback = await power.readback()
      guard operation == current else { return }
      phase = .failed
      message = error.localizedDescription
    }
  }

  private func reply(_ ok: Bool, code: String? = nil, text: String? = nil) -> HelperReply {
    let remaining = governor.lease.map { max(0, $0.expiry - clock()) }
    let state = HelperState(
      protocolVersion: HelperIdentity.protocolVersion, buildIdentity: buildIdentity,
      generation: governor.generation,
      ready: resetConfirmed
        && ((phase == .off && readback.confirmedDisabled)
          || (phase == .on && readback.confirmedEnabled)),
      phase: phase,
      enabled: phase == .on && governor.lease != nil && readback.confirmedEnabled,
      leaseID: governor.lease?.id, leaseRemainingSeconds: remaining, readback: readback,
      environment: environment(), stopReason: governor.lastStop, message: message)
    return HelperReply(ok: ok, code: code, message: text ?? message, state: state)
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
