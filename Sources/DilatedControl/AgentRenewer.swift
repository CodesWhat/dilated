import Darwin
import DilatedCore
import Foundation

/// Process facts the agent commands need, behind closures so tests can fake them.
public struct AgentPIDs: Sendable {
  /// Kernel start time of a live process, or nil when it's gone. A different start time is a
  /// different process that reused the pid.
  public var startMicros: @Sendable (Int32) -> Int64?
  /// The user that owns a process, or nil when there's no such process.
  public var owner: @Sendable (Int32) -> uid_t?
  public var uid: @Sendable () -> uid_t

  public init(
    startMicros: @escaping @Sendable (Int32) -> Int64?,
    owner: @escaping @Sendable (Int32) -> uid_t?,
    uid: @escaping @Sendable () -> uid_t
  ) {
    self.startMicros = startMicros
    self.owner = owner
    self.uid = uid
  }

  public static let system = AgentPIDs(
    startMicros: { ProcessStartTime.micros(pid: $0) },
    owner: { pid in
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid
      else { return nil }
      return info.kp_eproc.e_ucred.cr_uid
    },
    uid: { getuid() })
}

/// Keeps one run's lease alive across a long quiet turn. It runs in a detached `dilated agent
/// _renew` process, renews every two minutes while the agent process lives, and never begins or
/// releases anything: when it stops, the lease lapses on its own within one TTL.
public struct AgentRenewer {
  public enum Exit: Equatable, Sendable {
    case agentExited
    /// `end` ran, or a newer `begin` replaced the hold.
    case recordGone
    /// A renew came back not-found, paused or otherwise refused.
    case holdEnded
    case appUnavailable
  }

  private enum Event: Sendable { case exited, tick }

  public static let interval = Duration.seconds(120)
  static let allowedUnavailable = 2

  private let command: AgentCommand
  private let agentPID: Int32
  private let lifecycle: AgentLifecycle
  private let pids: AgentPIDs
  private let now: @Sendable () -> Date
  private let interval: Duration
  private let ticker: @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void
  private let onExit:
    @Sendable (Int32, Int64, @escaping @Sendable () -> Void) -> @Sendable () -> Void

  /// `lifecycle` carries the renew transport. `ticker` and `onExit` default to a dispatch timer
  /// and a dispatch process-exit source; tests drive both by hand.
  public init(
    agent: String, run: String, pid: Int32, lifecycle: AgentLifecycle,
    pids: AgentPIDs = .system, now: @escaping @Sendable () -> Date = { Date() },
    interval: Duration = AgentRenewer.interval,
    ticker: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void =
      ClosedLidWatchdog.timerTicker,
    onExit:
      @escaping @Sendable (Int32, Int64, @escaping @Sendable () -> Void) -> @Sendable () -> Void = {
        ProcessExit.register(pid: $0, startMicros: $1, handler: $2)
      }
  ) {
    self.command = AgentCommand(verb: .renew, agent: agent, run: run, json: false)
    self.agentPID = pid
    self.lifecycle = lifecycle
    self.pids = pids
    self.now = now
    self.interval = interval
    self.ticker = ticker
    self.onExit = onExit
  }

  public func run() async -> Exit {
    guard let agentStart = pids.startMicros(agentPID) else { return .agentExited }
    guard let holdID = lifecycle.currentRecord(for: command)?.holdID else { return .recordGone }
    // Dispatch sources feed one stream and this one task awaits it. No child Tasks, no async
    // sleeps: on macOS 26 those crash a long-lived detached helper (see ClosedLidWatchdog).
    let (stream, events) = AsyncStream.makeStream(of: Event.self)
    let cancelExit = onExit(agentPID, agentStart) { events.yield(.exited) }
    let cancelTimer = ticker(interval) { events.yield(.tick) }
    defer {
      cancelTimer()
      cancelExit()
      events.finish()
    }
    var unavailable = 0
    for await event in stream {
      guard event == .tick else { return .agentExited }
      guard pids.startMicros(agentPID) == agentStart else { return .agentExited }
      guard lifecycle.currentRecord(for: command)?.holdID == holdID else { return .recordGone }
      do {
        let response = try await lifecycle.run(command, now: now())
        unavailable = 0
        if !response.ok { return .holdEnded }
      } catch {
        unavailable += 1
        if unavailable >= Self.allowedUnavailable { return .appUnavailable }
      }
    }
    return .agentExited
  }
}

/// The hidden `dilated agent _renew` subcommand. Not listed in help.
public enum AgentRenewerCommand {
  public static let verb = "_renew"

  public static func matches(_ arguments: [String]) -> Bool {
    arguments.count >= 2 && arguments[0] == "agent" && arguments[1] == verb
  }

  public static func arguments(agent: String, run: String, pid: Int32) -> [String] {
    ["agent", verb, "--agent", agent, "--run", run, "--pid", String(pid)]
  }

  /// Syntax only: the agent may already be gone by the time this starts, and `run` handles that.
  public static func parse(_ arguments: [String]) throws -> (agent: String, run: String, pid: Int32)
  {
    guard matches(arguments), arguments.count == 8 else { throw InputError("Invalid renewer.") }
    var values: [String: String] = [:]
    var index = 2
    while index + 1 < arguments.count {
      guard values[arguments[index]] == nil else { throw InputError("Invalid renewer.") }
      values[arguments[index]] = arguments[index + 1]
      index += 2
    }
    guard let agent = values["--agent"], let run = values["--run"],
      let pid = values["--pid"].flatMap({ Int32($0) }), pid > 1
    else { throw InputError("Invalid renewer.") }
    try AgentCommand.validate(agent: agent, run: run)
    return (agent, run, pid)
  }

  /// Runs against the real app. The transport never launches the app: a closed app holds
  /// nothing, so there's nothing to keep alive.
  public static func run(
    _ arguments: [String], endpoint: SocketEndpoint = .current,
    transport: (@Sendable (ControlRequest) throws -> ControlResponse)? = nil
  ) async -> Int32 {
    guard let launch = try? parse(arguments) else { return 1 }
    let send =
      transport ?? { request in try LocalSocketClient.send(request, to: endpoint) }
    let lifecycle = AgentLifecycle(stateDirectory: endpoint.stateDirectory) { try send($0) }
    let renewer = AgentRenewer(
      agent: launch.agent, run: launch.run, pid: launch.pid, lifecycle: lifecycle)
    _ = await renewer.run()
    return 0
  }
}

struct AgentRenewerSpawnError: LocalizedError {
  let detail: String
  var errorDescription: String? { detail }
}

/// Starts `dilated agent _renew` in its own session with stdio on /dev/null, the same way the app
/// starts the closed-lid watchdog, so it outlives the hook that began the run.
public enum AgentRenewerSpawner {
  @discardableResult
  public static func spawn(executable: URL, agent: String, run: String, pid: Int32) throws
    -> Int32
  {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw AgentRenewerSpawnError(detail: "The agent renewer isn't available.")
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Default signal dispositions and an empty mask, so SIGTERM stops it even if the hook's shell
    // started us with it ignored or blocked.
    var defaults = sigset_t()
    sigfillset(&defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    let arguments =
      [executable.path] + AgentRenewerCommand.arguments(agent: agent, run: run, pid: pid)
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    // The renewer finds the app's socket through DILATED_STATE_DIR, so it keeps our environment.
    var envp: [UnsafeMutablePointer<CChar>?] =
      ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in envp { free(pointer) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, executable.path, &actions, &attributes, &argv, &envp)
    guard status == 0 else {
      throw AgentRenewerSpawnError(detail: "Couldn't start the agent renewer (\(status)).")
    }
    // Detached from our session and reparented to launchd when we exit, so nothing to reap
    // beyond the short window while this CLI is still running.
    return child
  }
}
