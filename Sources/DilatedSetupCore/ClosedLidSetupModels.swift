import DilatedCore
import Foundation

/// Where everything the companion touches lives, for one user and the Mac App Store bundle ID.
public struct ClosedLidSetupPaths: Equatable, Sendable {
  public static let appStoreBundleID = "com.codeswhat.dilated.appstore"
  public static let agentLabel = "com.codeswhat.dilated.closed-lid-repair"
  public static let scriptName = "dilated-power"

  public var home: String
  public var uid: UInt32
  public var bundleID: String

  public init(home: String, uid: UInt32, bundleID: String = Self.appStoreBundleID) {
    self.home = home
    self.uid = uid
    self.bundleID = bundleID
  }

  public static func current() -> ClosedLidSetupPaths {
    ClosedLidSetupPaths(home: NSHomeDirectory(), uid: getuid())
  }

  public var scriptsDirectory: String { "\(home)/Library/Application Scripts/\(bundleID)" }
  public var scriptPath: String { "\(scriptsDirectory)/\(Self.scriptName)" }
  public var agentPlistPath: String { "\(home)/Library/LaunchAgents/\(Self.agentLabel).plist" }
  public var agentTarget: String { "gui/\(uid)/\(Self.agentLabel)" }
  public var agentDomain: String { "gui/\(uid)" }
  /// The session record `dilated-power on` writes. A file here means closed-lid mode may be on.
  public var sessionFile: String { "\(home)/Library/Application Support/dilated-power/session" }
  public var stateDirectory: String {
    "\(home)/Library/Application Support/Dilated Closed-Lid Setup"
  }
  public var stateFile: String { "\(stateDirectory)/state.json" }
}

/// The two files the companion ships and the hash the script has to match before it's installed.
public struct ClosedLidSetupAssets: Sendable {
  /// SHA-256 of `packaging/mas/dilated-power`. A test fails when the script changes without this
  /// being updated, so a stale value can't ship.
  public static let expectedScriptSHA256 =
    "d231edd1e3ca11d0cb7d1a7695dbcc61de134106f1fe57d97bd4d2e3174b46bd"

  public var script: Data
  public var plistTemplate: String
  public var expectedScriptSHA256: String

  public init(
    script: Data, plistTemplate: String,
    expectedScriptSHA256: String = ClosedLidSetupAssets.expectedScriptSHA256
  ) {
    self.script = script
    self.plistTemplate = plistTemplate
    self.expectedScriptSHA256 = expectedScriptSHA256
  }

  /// The copies bundled with the setup target. Missing files load as empty, and install refuses
  /// them because the hash can't match.
  public static func bundled() -> ClosedLidSetupAssets {
    let bundle = Bundle.module
    let script = bundle.url(forResource: ClosedLidSetupPaths.scriptName, withExtension: nil)
      .flatMap { try? Data(contentsOf: $0) }
    let plist = bundle.url(
      forResource: ClosedLidSetupPaths.agentLabel, withExtension: "plist"
    ).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    return ClosedLidSetupAssets(script: script ?? Data(), plistTemplate: plist ?? "")
  }

  /// What the packaged app reports for `--assets --json`: whether the bundled files resolved and match.
  public var verificationJSON: String {
    let report: [String: Any] = [
      "scriptSHA256": ClosedLidSetup.sha256(script),
      "scriptMatches": ClosedLidSetup.sha256(script) == expectedScriptSHA256,
      "plistValid": plistTemplate.contains("__HOME__"),
    ]
    let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  public func renderedPlist(home: String) -> Data {
    Data(plistTemplate.replacingOccurrences(of: "__HOME__", with: home).utf8)
  }
}

public enum ClosedLidSetupRuleStatus: String, Codable, Equatable, Sendable {
  case ready, allowedByOtherRule, missing, needsRepair, blocked, notAdmin

  init(_ state: ClosedLidPermissionState) {
    switch state {
    case .ready: self = .ready
    case .allowedByOtherRule: self = .allowedByOtherRule
    case .notInstalled: self = .missing
    case .needsRepair: self = .needsRepair
    case .blocked: self = .blocked
    case .notAdmin: self = .notAdmin
    }
  }
}

public enum ClosedLidSetupScriptStatus: String, Codable, Equatable, Sendable {
  case present, outdated, missing
}

public enum ClosedLidSetupAgentStatus: String, Codable, Equatable, Sendable {
  case loaded, notLoaded
}

public struct ClosedLidSetupStatus: Codable, Equatable, Sendable {
  public var rule: ClosedLidSetupRuleStatus
  public var script: ClosedLidSetupScriptStatus
  public var agent: ClosedLidSetupAgentStatus
  /// Whether the companion wrote the sudoers rule, which decides if remove may delete it.
  public var ruleInstalledByCompanion: Bool

  public init(
    rule: ClosedLidSetupRuleStatus, script: ClosedLidSetupScriptStatus,
    agent: ClosedLidSetupAgentStatus, ruleInstalledByCompanion: Bool
  ) {
    self.rule = rule
    self.script = script
    self.agent = agent
    self.ruleInstalledByCompanion = ruleInstalledByCompanion
  }

  /// Everything the Mac App Store build needs is in place.
  public var isInstalled: Bool {
    (rule == .ready || rule == .allowedByOtherRule) && script == .present && agent == .loaded
  }

  public var jsonString: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
  }
}

public enum ClosedLidSetupOutcome: Equatable, Sendable {
  case completed
  /// The user dismissed the administrator prompt. Nothing past that step ran.
  case cancelled
  case failed(String)
}

/// What the companion remembers between runs. Only whether it wrote the shared rule.
struct ClosedLidSetupRecord: Codable, Equatable {
  var ruleInstalledByCompanion: Bool
}

// MARK: Side effects

public protocol SetupFileSystem: Sendable {
  func read(_ path: String) -> Data?
  func exists(_ path: String) -> Bool
  /// Writes a temp file in the target's folder, sets its mode, then renames it over the target.
  /// Missing parent folders are created with `directoryMode`.
  func writeAtomically(_ data: Data, to path: String, mode: UInt16, directoryMode: UInt16) throws
  /// A missing path is not an error.
  func remove(_ path: String) throws
  /// Removes the folder only if it exists and has nothing in it.
  func removeDirectoryIfEmpty(_ path: String)
}

public protocol LaunchAgentControlling: Sendable {
  func bootstrap(domain: String, plistPath: String) async throws
  /// Failure is ignored: the agent not being loaded is the normal case.
  func bootout(target: String) async
  func isLoaded(target: String) async -> Bool
}

public protocol PowerScriptRunning: Sendable {
  /// Runs `dilated-power off`, which turns sleep back on and deletes the session record.
  func off(scriptPath: String) async throws
}

/// The sudoers rule, which `ClosedLidPermission` already implements.
public protocol ClosedLidRuleControlling: Sendable {
  func state() async -> ClosedLidPermissionState
  func install() async -> ClosedLidPermissionOutcome
  func remove() async -> ClosedLidPermissionOutcome
}

extension ClosedLidPermission: ClosedLidRuleControlling {}
