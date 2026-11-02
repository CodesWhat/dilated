import Darwin
import Foundation

public enum ClosedLidPermissionState: Equatable, Sendable {
  case notInstalled, needsRepair, blocked, ready, notAdmin
  /// Our rule file is absent but another app's sudoers rule already allows both `pmset` commands.
  case allowedByOtherRule

  /// The word the CLI prints and the control socket carries.
  public var word: String {
    switch self {
    case .notInstalled: "notInstalled"
    case .needsRepair: "needsRepair"
    case .blocked: "blocked"
    case .ready: "ready"
    case .notAdmin: "notAdmin"
    case .allowedByOtherRule: "allowedByOtherRule"
    }
  }

  /// Whether closed-lid can run: our own rule works, or another app's rule covers it.
  public var isUsable: Bool { self == .ready || self == .allowedByOtherRule }
}

public struct ClosedLidFileInfo: Equatable, Sendable {
  public var isRegularFile: Bool
  public var owner: UInt32
  public var group: UInt32
  public var mode: UInt16
  public var size: Int

  public init(
    isRegularFile: Bool, owner: UInt32, group: UInt32, mode: UInt16,
    size: Int = ClosedLidPermission.ruleContent.count
  ) {
    self.isRegularFile = isRegularFile
    self.owner = owner
    self.group = group
    self.mode = mode
    self.size = size
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
  /// One `sudo -n -l` probe per command the rule has to cover. Both must succeed.
  static let probeArgumentSets = ["1", "0"].map {
    ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", $0]
  }

  static let installScript = [
    "set -eu",
    "umask 077",
    "tmp=$(/usr/bin/mktemp \(scratchDirectory)/dilated-sudoers.XXXXXX)",
    "stage=\(stagingPath)",
    "trap '/bin/rm -f \"$tmp\" \"$stage\"' EXIT",
    "/usr/bin/printf '%s\\n%s\\n' '\(ruleLines[0])' '\(ruleLines[1])' > \"$tmp\"",
    "/usr/sbin/visudo -cf \"$tmp\"",
    "/usr/bin/install -o root -g wheel -m 0440 \"$tmp\" \"$stage\"",
    "/bin/mv -f \"$stage\" \(rulePath)",
    "/usr/sbin/visudo -cf \(rulePath) || { /bin/rm -f \(rulePath); exit 1; }",
  ].joined(separator: "; ")

  static let removeScript = [
    "set -eu",
    "/bin/rm -f \(rulePath)",
    "test ! -e \(rulePath)",
  ].joined(separator: "; ")

  static let restoreScript = "/usr/bin/pmset -a disablesleep 0"

  /// The AppleScript that runs a fixed shell script as root. Only backslashes and double quotes
  /// need escaping, and the scripts above are constants.
  static func appleScriptSource(for script: String) -> String {
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges"
  }

  /// `osascript` reports the user dismissing the admin prompt as AppleScript error -128.
  static func outcome(status: Int32, stderr: String, timedOut: Bool = false)
    -> PrivilegedScriptOutcome
  {
    if timedOut { return .failed("The administrator prompt timed out.") }
    if status == 0 { return .succeeded }
    if stderr.contains("-128") || stderr.contains("User canceled") { return .cancelled }
    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(message.isEmpty ? "The administrator command failed." : message)
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
    seams: Seams = .live, runner: any PrivilegedScriptRunning = OsascriptAdminRunner()
  ) {
    self.seams = seams
    self.runner = runner
  }

  public func state() async -> ClosedLidPermissionState {
    guard seams.isAdmin() else { return .notAdmin }
    guard let info = seams.stat(Self.rulePath) else {
      return await seams.probe() ? .allowedByOtherRule : .notInstalled
    }
    // The file is 0440 root:wheel, so the app can't read it. Size stands in for the bytes, and
    // they're compared only if the file happens to be readable.
    guard info.isRegularFile, info.owner == 0, info.group == 0, info.mode == 0o440,
      info.size == Self.ruleContent.count
    else { return .needsRepair }
    if let bytes = seams.readFile(Self.rulePath), bytes != Self.ruleContent {
      return .needsRepair
    }
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
      return ClosedLidFileInfo(
        isRegularFile: false, owner: UInt32.max, group: UInt32.max, mode: 0, size: 0)
    }
    return ClosedLidFileInfo(
      isRegularFile: info.st_mode & S_IFMT == S_IFREG, owner: info.st_uid, group: info.st_gid,
      mode: info.st_mode & 0o7777, size: Int(info.st_size))
  }

  static func liveProbe() async -> Bool {
    for arguments in probeArgumentSets {
      guard
        let result = try? await BoundedProcess.run(
          executable: URL(fileURLWithPath: SudoPowerRunner.sudoPath), arguments: arguments,
          timeout: 3, environment: [:]),
        !result.timedOut, result.status == 0
      else { return false }
    }
    return true
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

/// Runs a fixed shell script as root through the standard macOS administrator prompt, using
/// `osascript` in a child process so the app (and its control socket) stays responsive while the
/// dialog is open. The 5 minute bound is separate from `BoundedProcess`'s 3 second cap.
public struct OsascriptAdminRunner: PrivilegedScriptRunning {
  public static let promptTimeout: TimeInterval = 300
  private let executable: URL
  private let timeout: TimeInterval

  public init(
    executable: URL = URL(fileURLWithPath: "/usr/bin/osascript"),
    timeout: TimeInterval = OsascriptAdminRunner.promptTimeout
  ) {
    self.executable = executable
    self.timeout = timeout
  }

  public func run(script source: String) async -> PrivilegedScriptOutcome {
    await Self.execute(executable: executable, arguments: ["-e", source], timeout: timeout)
  }

  /// Runs the process on a dispatch thread, never the main actor or the cooperative pool.
  static func execute(executable: URL, arguments: [String], timeout: TimeInterval) async
    -> PrivilegedScriptOutcome
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    let state = ExecutionState()
    return await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<PrivilegedScriptOutcome, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
          do { try process.run() } catch {
            continuation.resume(returning: .failed("The administrator command couldn't start."))
            return
          }
          state.attach(process)
          let watchdog = DispatchWorkItem {
            state.markTimedOut()
            state.terminate()
          }
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
          let data = errors.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          watchdog.cancel()
          continuation.resume(
            returning: ClosedLidPermission.outcome(
              status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self),
              timedOut: state.timedOut))
        }
      }
    } onCancel: {
      state.terminate()
    }
  }

  private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private(set) var timedOutFlag = false

    var timedOut: Bool { lock.withLock { timedOutFlag } }

    func attach(_ process: Process) {
      let stopNow = lock.withLock {
        self.process = process
        return cancelled
      }
      if stopNow, process.isRunning { process.terminate() }
    }

    func markTimedOut() { lock.withLock { timedOutFlag = true } }

    func terminate() {
      let held = lock.withLock {
        cancelled = true
        return process
      }
      if let held, held.isRunning { held.terminate() }
    }
  }
}
