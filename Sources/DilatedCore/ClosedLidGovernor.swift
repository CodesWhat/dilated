import Foundation

public enum ClosedLidPowerSource: String, Codable, Sendable { case ac, battery, unknown }
public enum ClosedLidThermal: String, Codable, Sendable {
  case nominal, fair, serious, critical, unknown
}
public struct ClosedLidEnvironment: Codable, Equatable, Sendable {
  public var powerSource: ClosedLidPowerSource
  public var batteryPercent: Int?
  public var lowPowerMode: Bool
  public var thermal: ClosedLidThermal
  public var lidClosed: Bool?

  public init(
    powerSource: ClosedLidPowerSource = .unknown, batteryPercent: Int? = nil,
    lowPowerMode: Bool = false, thermal: ClosedLidThermal = .unknown, lidClosed: Bool? = nil
  ) {
    self.powerSource = powerSource
    self.batteryPercent = batteryPercent
    self.lowPowerMode = lowPowerMode
    self.thermal = thermal
    self.lidClosed = lidClosed
  }
}
public struct ClosedLidPolicy: Codable, Equatable, Sendable {
  public var batteryFloor: Int
  public var maximumBatteryClosedSeconds: TimeInterval
  public var acOnly: Bool
  public var overrideLowPower: Bool

  public init(
    batteryFloor: Int = 20, maximumBatteryClosedSeconds: TimeInterval = 8 * 3600,
    acOnly: Bool = false, overrideLowPower: Bool = false
  ) {
    self.batteryFloor = batteryFloor
    self.maximumBatteryClosedSeconds = maximumBatteryClosedSeconds
    self.acOnly = acOnly
    self.overrideLowPower = overrideLowPower
  }
}
public enum ClosedLidStopReason: String, Codable, Sendable, LocalizedError {
  case disabled, disconnected, noClosedLidHolds, leaseExpired, invalidClock, lowBattery,
    lowPowerMode, thermal, requiresAC, batteryTimeLimit, telemetryUnavailable

  public var errorDescription: String? {
    switch self {
    case .disabled: "Closed-lid mode is off."
    case .disconnected:
      "Closed-lid stopped because the app disconnected. Enable it again to continue."
    case .noClosedLidHolds: "Closed-lid stopped because its awake holds ended."
    case .leaseExpired:
      "Closed-lid stopped because the app stopped responding. Enable it again to continue."
    case .invalidClock: "Closed-lid stopped because its safety clock couldn't be verified."
    case .lowBattery: "Closed-lid stopped below the battery floor. Enable it again after charging."
    case .lowPowerMode: "Closed-lid stopped for Low Power Mode."
    case .thermal: "Closed-lid stopped because the Mac is too hot. Enable it again after it cools."
    case .requiresAC: "Closed-lid mode is set to require a power adapter."
    case .batteryTimeLimit:
      "Closed-lid stopped at the battery time limit. Enable it again to continue."
    case .telemetryUnavailable: "Closed-lid stopped because its safety readings are unavailable."
    }
  }
}
public enum ClosedLidError: Error, Equatable, Sendable, LocalizedError {
  case invalidPolicy, alreadyActive, missingLease, notLeaseOwner
  case unsafe(ClosedLidStopReason)

  public var errorDescription: String? {
    switch self {
    case .invalidPolicy:
      "Use a battery floor of 10–100% and a battery time limit of 1 minute to 24 hours."
    case .alreadyActive: "Closed-lid mode already has an active lease."
    case .missingLease: "That closed-lid lease has ended. Enable closed-lid again to continue."
    case .notLeaseOwner: "That closed-lid lease belongs to a different app connection."
    case .unsafe(let reason): reason.localizedDescription
    }
  }
}
public struct ClosedLidLease: Equatable, Sendable {
  public let id: UUID
  public let owner: UUID
  public var expiry: TimeInterval
  public var lastObserved: TimeInterval
  public var batteryClosedSince: TimeInterval?
  public let policy: ClosedLidPolicy
}
public struct ClosedLidStop: Equatable, Sendable {
  public let reason: ClosedLidStopReason
  public let requestSleep: Bool
}

public struct ClosedLidGovernor: Sendable {
  public static let leaseSeconds: TimeInterval = 90
  public let generation = UUID()
  public private(set) var lease: ClosedLidLease?
  public private(set) var lastStop: ClosedLidStopReason?

  public init() {}

  @discardableResult public mutating func begin(
    owner: UUID, policy: ClosedLidPolicy, environment: ClosedLidEnvironment, now: TimeInterval
  ) throws -> UUID {
    guard lease == nil else { throw ClosedLidError.alreadyActive }
    guard (10...100).contains(policy.batteryFloor),
      policy.maximumBatteryClosedSeconds.isFinite,
      (60...86400).contains(policy.maximumBatteryClosedSeconds)
    else { throw ClosedLidError.invalidPolicy }
    guard now.isFinite, now >= 0 else { throw ClosedLidError.unsafe(.invalidClock) }
    if let reason = veto(environment: environment, policy: policy) {
      lastStop = reason
      throw ClosedLidError.unsafe(reason)
    }
    let id = UUID()
    lease = ClosedLidLease(
      id: id, owner: owner, expiry: now + Self.leaseSeconds, lastObserved: now,
      batteryClosedSince: countsBatteryTime(environment) ? now : nil, policy: policy)
    lastStop = nil
    return id
  }

  @discardableResult public mutating func heartbeat(
    owner: UUID, id: UUID, environment: ClosedLidEnvironment, now: TimeInterval
  ) throws -> ClosedLidStop? {
    guard let current = lease, current.id == id else { throw ClosedLidError.missingLease }
    guard current.owner == owner else { throw ClosedLidError.notLeaseOwner }
    if let stopped = reconcile(environment: environment, now: now) { return stopped }
    lease?.expiry = now + Self.leaseSeconds
    return nil
  }

  @discardableResult public mutating func reconcile(
    environment: ClosedLidEnvironment, now: TimeInterval
  ) -> ClosedLidStop? {
    guard var current = lease else { return nil }
    let reason: ClosedLidStopReason?
    if !now.isFinite || now < current.lastObserved {
      reason = .invalidClock
    } else if now >= current.expiry {
      reason = .leaseExpired
    } else if let unsafe = veto(environment: environment, policy: current.policy) {
      reason = unsafe
    } else {
      current.batteryClosedSince =
        countsBatteryTime(environment) ? current.batteryClosedSince ?? now : nil
      reason =
        current.batteryClosedSince.map {
          now - $0 >= current.policy.maximumBatteryClosedSeconds ? .batteryTimeLimit : nil
        } ?? nil
    }
    if let reason { return stop(reason: reason, environment: environment) }
    current.lastObserved = now
    lease = current
    return nil
  }

  @discardableResult public mutating func disconnected(
    owner: UUID, environment: ClosedLidEnvironment
  ) -> ClosedLidStop? {
    guard lease?.owner == owner else { return nil }
    return stop(reason: .disconnected, environment: environment)
  }

  @discardableResult public mutating func stop(
    reason: ClosedLidStopReason, environment: ClosedLidEnvironment
  ) -> ClosedLidStop? {
    guard lease != nil else { return nil }
    lease = nil
    lastStop = reason
    return ClosedLidStop(reason: reason, requestSleep: environment.lidClosed == true)
  }

  private func countsBatteryTime(_ environment: ClosedLidEnvironment) -> Bool {
    environment.powerSource == .battery && environment.lidClosed == true
  }

  private func veto(
    environment: ClosedLidEnvironment, policy: ClosedLidPolicy
  ) -> ClosedLidStopReason? {
    guard environment.powerSource != .unknown, environment.thermal != .unknown,
      environment.lidClosed != nil
    else { return .telemetryUnavailable }
    if environment.thermal == .serious || environment.thermal == .critical { return .thermal }
    if environment.powerSource == .battery {
      guard let percent = environment.batteryPercent, (0...100).contains(percent) else {
        return .telemetryUnavailable
      }
      if percent < policy.batteryFloor { return .lowBattery }
      if policy.acOnly { return .requiresAC }
    }
    if environment.lowPowerMode && !policy.overrideLowPower { return .lowPowerMode }
    return nil
  }
}
