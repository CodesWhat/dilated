import Foundation

public enum HelperIdentity {
  public static let appID = "com.codeswhat.dilated"
  public static let serviceID = "com.codeswhat.dilated.helper"
  public static let plistName = serviceID + ".plist"
  public static let protocolVersion = 1
  public static let maximumMessageBytes = 16 * 1024
  public static let appRequirement =
    "identifier \"com.codeswhat.dilated\" and anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\""
  public static let helperRequirement =
    "identifier \"com.codeswhat.dilated.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"3524374A2S\""
}

@objc public protocol HelperXPCProtocol {
  func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum HelperAction: String, Codable, Sendable {
  case status, enable, heartbeat, disable, sleep
}
public enum HelperPhase: String, Codable, Sendable {
  case starting, off, enabling, on, disabling, sleeping, failed
}
public struct HelperRequest: Codable, Sendable {
  public var action: HelperAction
  public var leaseID: UUID?
  public var policy: ClosedLidPolicy?
  public var protocolVersion: Int

  public init(
    action: HelperAction, leaseID: UUID? = nil, policy: ClosedLidPolicy? = nil,
    protocolVersion: Int = HelperIdentity.protocolVersion
  ) {
    self.action = action
    self.leaseID = leaseID
    self.policy = policy
    self.protocolVersion = protocolVersion
  }
}
public struct HelperState: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var buildIdentity: String
  public var generation: UUID
  public var ready: Bool
  public var phase: HelperPhase
  public var enabled: Bool
  public var leaseID: UUID?
  public var leaseRemainingSeconds: TimeInterval?
  public var readback: ClosedLidReadback
  public var environment: ClosedLidEnvironment
  public var stopReason: ClosedLidStopReason?
  public var message: String?
}
public struct HelperReply: Codable, Sendable {
  public var ok: Bool
  public var code: String?
  public var message: String?
  public var state: HelperState?

  public init(ok: Bool, code: String? = nil, message: String? = nil, state: HelperState? = nil) {
    self.ok = ok
    self.code = code
    self.message = message
    self.state = state
  }
}
