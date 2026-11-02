import Darwin
import Foundation

public enum ClosedLidPermissionState: Equatable, Sendable {
  case notInstalled, needsRepair, blocked, ready, notAdmin

  /// The word the CLI prints and the control socket carries.
  public var word: String {
    switch self {
    case .notInstalled: "notInstalled"
    case .needsRepair: "needsRepair"
    case .blocked: "blocked"
    case .ready: "ready"
    case .notAdmin: "notAdmin"
    }
  }
}

public struct ClosedLidFileInfo: Equatable, Sendable {
  public var isRegularFile: Bool
  public var owner: UInt32
  public var group: UInt32
  public var mode: UInt16

  public init(isRegularFile: Bool, owner: UInt32, group: UInt32, mode: UInt16) {
    self.isRegularFile = isRegularFile
    self.owner = owner
    self.group = group
    self.mode = mode
  }
}

public enum PrivilegedScriptOutcome: Equatable, Sendable {
  case succeeded, cancelled
  case failed(String)
}

public protocol PrivilegedScriptRunning: Sendable {
  func run(script: String) async -> PrivilegedScriptOutcome
}

public enum ClosedLidPermissionOutcome: Equatable, Sendable {
  case completed(ClosedLidPermissionState)
  case cancelled
  case failed(String, ClosedLidPermissionState)
}

/// Detects, installs and removes the sudoers rule that lets Dilated run the two `pmset` commands
/// it needs without a root helper. Every side-effecting dependency is injected.
public struct ClosedLidPermission: Sendable {
  public static let rulePath = "/private/etc/sudoers.d/dilated"
  static let stagingPath = "/private/etc/sudoers.d/.dilated-staging"
  static let scratchDirectory = "/private/var/root"
  static let ruleLines = [
    "Cmnd_Alias DILATED_PMSET = /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
    "%admin ALL=(root) NOPASSWD: DILATED_PMSET",
  ]
  public static let ruleContent = Data((ruleLines.joined(separator: "\n") + "\n").utf8)
  static let probeArguments = ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]

  static let installScript = [
    "set -eu",
    "umask 077",
    "tmp=$(/usr/bin/mktemp \(scratchDirectory)/dilated-sudoers.XXXXXX)",
    "stage=\(stagingPath)",
    "trap '/bin/rm -f \"$tmp\" \"$stage\"' EXIT",
    "/usr/bin/printf '%s\\n%s\\n' '\(ruleLines[0])' '\(ruleLines[1])' > \"$tmp\"",
    "/usr/sbin/visudo -cf \"$tmp\"",
    "/usr/bin/install -o root -g wheel -m 0444 \"$tmp\" \"$stage\"",
    "/bin/mv -f \"$stage\" \(rulePath)",
    "/usr/sbin/visudo -c || { /bin/rm -f \(rulePath); exit 1; }",
  ].joined(separator: "; ")

  static let removeScript = [
    "set -eu",
    "/bin/rm -f \(rulePath)",
    "/usr/sbin/visudo -c",
  ].joined(separator: "; ")

  static let restoreScript = "/usr/bin/pmset -a disablesleep 0"

  /// The AppleScript that runs a fixed shell script as root. Only backslashes and double quotes
  /// need escaping, and the scripts above are constants.
  static func appleScriptSource(for script: String) -> String {
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges"
  }

  /// AppleScript error -128 is the user dismissing the admin prompt.
  static func outcome(errorNumber: Int?, message: String?) -> PrivilegedScriptOutcome {
    if errorNumber == -128 { return .cancelled }
    return .failed(message ?? "The administrator command failed.")
  }

  public struct Seams: Sendable {
    public var stat: @Sendable (String) -> ClosedLidFileInfo?
    public var readFile: @Sendable (String) -> Data?
    public var probe: @Sendable () async -> Bool
    public var isAdmin: @Sendable () -> Bool

    public init(
      stat: @escaping @Sendable (String) -> ClosedLidFileInfo?,
      readFile: @escaping @Sendable (String) -> Data?,
      probe: @escaping @Sendable () async -> Bool,
      isAdmin: @escaping @Sendable () -> Bool
    ) {
      self.stat = stat
      self.readFile = readFile
      self.probe = probe
      self.isAdmin = isAdmin
    }

    public static let live = Seams(
      stat: ClosedLidPermission.liveStat, readFile: { FileManager.default.contents(atPath: $0) },
      probe: ClosedLidPermission.liveProbe, isAdmin: ClosedLidPermission.currentUserIsAdmin)
  }

  private let seams: Seams
  private let runner: any PrivilegedScriptRunning

  public init(
    seams: Seams = .live, runner: any PrivilegedScriptRunning = AppleScriptAdminRunner()
  ) {
    self.seams = seams
    self.runner = runner
  }

  public func state() async -> ClosedLidPermissionState {
    guard seams.isAdmin() else { return .notAdmin }
    guard let info = seams.stat(Self.rulePath) else { return .notInstalled }
    guard info.isRegularFile, info.owner == 0, info.group == 0, info.mode == 0o444,
      seams.readFile(Self.rulePath) == Self.ruleContent
    else { return .needsRepair }
    return await seams.probe() ? .ready : .blocked
  }

  public func install() async -> ClosedLidPermissionOutcome {
    guard seams.isAdmin() else {
      return .failed("Your account isn't an administrator, so the rule can't cover it.", .notAdmin)
    }
    return await perform(Self.installScript)
  }

  public func remove() async -> ClosedLidPermissionOutcome {
    await perform(Self.removeScript)
  }

  /// The password-backed fallback: turns sleep back on without the sudo rule.
  public func restoreNormalSleep() async -> PrivilegedScriptOutcome {
    await runner.run(script: Self.appleScriptSource(for: Self.restoreScript))
  }

  private func perform(_ script: String) async -> ClosedLidPermissionOutcome {
    switch await runner.run(script: Self.appleScriptSource(for: script)) {
    case .cancelled: return .cancelled
    case .succeeded: return .completed(await state())
    case .failed(let message): return .failed(message, await state())
    }
  }

  static func liveStat(_ path: String) -> ClosedLidFileInfo? {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { return nil }
      return ClosedLidFileInfo(isRegularFile: false, owner: UInt32.max, group: UInt32.max, mode: 0)
    }
    return ClosedLidFileInfo(
      isRegularFile: info.st_mode & S_IFMT == S_IFREG, owner: info.st_uid, group: info.st_gid,
      mode: info.st_mode & 0o7777)
  }

  static func liveProbe() async -> Bool {
    guard
      let result = try? await BoundedProcess.run(
        executable: URL(fileURLWithPath: SudoPowerRunner.sudoPath), arguments: probeArguments,
        timeout: 3, environment: [:])
    else { return false }
    return !result.timedOut && result.status == 0
  }

  static func currentUserIsAdmin() -> Bool {
    guard let group = getgrnam("admin"), let user = getpwuid(geteuid()) else { return false }
    let adminGroup = group.pointee.gr_gid
    var count: Int32 = 64
    var groups = [Int32](repeating: 0, count: Int(count))
    let name = user.pointee.pw_name
    let base = Int32(bitPattern: user.pointee.pw_gid)
    var status = getgrouplist(name, base, &groups, &count)
    if status == -1 {
      groups = [Int32](repeating: 0, count: Int(count))
      status = getgrouplist(name, base, &groups, &count)
    }
    guard status != -1 else { return false }
    return groups.prefix(Int(count)).contains { UInt32(bitPattern: $0) == adminGroup }
  }
}

/// Runs a fixed shell script as root through the standard macOS administrator prompt.
public struct AppleScriptAdminRunner: PrivilegedScriptRunning {
  public init() {}

  public func run(script source: String) async -> PrivilegedScriptOutcome {
    await MainActor.run {
      var error: NSDictionary?
      guard let script = NSAppleScript(source: source) else {
        return .failed("The administrator command couldn't be prepared.")
      }
      _ = script.executeAndReturnError(&error)
      guard let error else { return .succeeded }
      return ClosedLidPermission.outcome(
        errorNumber: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue,
        message: error[NSAppleScript.errorMessage] as? String)
    }
  }
}
