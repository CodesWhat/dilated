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
  /// The app's `DILATED_STATE_DIR`, when set. The session lock lives there, so setup has to follow.
  public var stateDirectoryOverride: String?

  public init(
    home: String, uid: UInt32, bundleID: String = Self.appStoreBundleID,
    stateDirectoryOverride: String? = nil
  ) {
    self.stateDirectoryOverride = stateDirectoryOverride
    self.home = home
    self.uid = uid
    self.bundleID = bundleID
  }

  public static func current() -> ClosedLidSetupPaths {
    ClosedLidSetupPaths(
      home: NSHomeDirectory(), uid: getuid(),
      stateDirectoryOverride: ProcessInfo.processInfo.environment[
        DilatedStateDirectory.environmentKey])
  }

  public var scriptsDirectory: String { "\(home)/Library/Application Scripts/\(bundleID)" }
  public var scriptPath: String { "\(scriptsDirectory)/\(Self.scriptName)" }
  public var agentPlistPath: String { "\(home)/Library/LaunchAgents/\(Self.agentLabel).plist" }
  public var agentTarget: String { "gui/\(uid)/\(Self.agentLabel)" }
  public var agentDomain: String { "gui/\(uid)" }
  /// The session record `dilated-power on` writes. A file here means closed-lid mode may be on.
  public var sessionFile: String { "\(home)/Library/Application Support/dilated-power/session" }
  /// Written by `dilated-power begin-removal`. While it exists the script refuses `on`; install
  /// clears it once the repair agent is loaded again.
  public var removalMarker: String { "\(home)/Library/Application Support/dilated-power/removal" }
  /// Written by `dilated-power begin-removal` before it restores an owned session, and cleared only
  /// by `finish-removal`. While it exists, removal still owns the restore after `off` or `repair`
  /// deleted the session, so the readback can't be skipped.
  public var restorePendingFile: String {
    "\(home)/Library/Application Support/dilated-power/restore-pending"
  }
  public var stateDirectory: String {
    "\(home)/Library/Application Support/Dilated Closed-Lid Setup"
  }
  /// The direct build's marker-store lock, which every closed-lid enable, restore and watchdog
  /// revert holds. Setup runs unsandboxed as the user, so it reaches the same file the app does.
  public var sessionLockFile: String {
    DilatedStateDirectory.resolve(
      environment: stateDirectoryOverride.map { [DilatedStateDirectory.environmentKey: $0] } ?? [:],
      applicationSupport: URL(fileURLWithPath: "\(home)/Library/Application Support")
    )
    .appendingPathComponent(ClosedLidMarkerStore.lockFileName).path
  }
  public var stateFile: String { "\(stateDirectory)/state.json" }
}

/// The two files the companion ships and the hash the script has to match before it's installed.
public struct ClosedLidSetupAssets: Sendable {
  /// SHA-256 of `packaging/mas/dilated-power`. A test fails when the script changes without this
  /// being updated, so a stale value can't ship.
  public static let expectedScriptSHA256 =
    "c50338b3dd7de9755b524913f18256d80e5fb013793c6b235cd9b42e111694c7"

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
  /// Runs `dilated-power begin-removal`: under the script's lock it writes the removal marker,
  /// turns sleep back on and clears the session, so a running app can't enable again. Returns
  /// whether a session file was ours (it stays on disk); when it wasn't, sleep was left untouched.
  func beginRemoval(scriptPath: String) async throws -> Bool
  /// Runs `dilated-power finish-removal`: deletes the session record, after the readback passed.
  func finishRemoval(scriptPath: String) async throws
  /// Whether macOS reads back normal sleep (not disabled, stored or effective).
  func confirmsNormalSleep() async -> Bool
}

/// The sudoers rule, which `ClosedLidPermission` already implements.
public protocol ClosedLidRuleControlling: Sendable {
  func state() async -> ClosedLidPermissionState
  func install() async -> ClosedLidPermissionOutcome
  func remove() async -> ClosedLidPermissionOutcome
}

extension ClosedLidPermission: ClosedLidRuleControlling {}
