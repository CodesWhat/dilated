import Darwin
import DilatedCore
import Foundation

/// `dilated agent begin|renew|end --agent NAME --run ID`: an idempotent, Stop-safe wrapper over the
/// renewable hold API so any agent hook can call one contract. It keeps a run-id to hold-id record
/// under the state directory and never recreates a hold after Stop or an ended-ID reply.
public struct AgentCommand: Equatable, Sendable {
  public enum Verb: String, Sendable { case begin, renew, end }
  public var verb: Verb
  public var agent: String
  public var run: String
  public var json: Bool
  /// The agent process ID. CLI `begin --pid` and hook begin/renew commands use it to start
  /// a detached renewer while that process runs.
  public var pid: Int32?
  public var decidedByHook: Bool

  public init(
    verb: Verb, agent: String, run: String, json: Bool, pid: Int32? = nil,
    decidedByHook: Bool = false
  ) {
    self.verb = verb
    self.agent = agent
    self.run = run
    self.json = json
    self.pid = pid
    self.decidedByHook = decidedByHook
  }

  static let usage =
    "Use dilated agent begin|renew|end --agent NAME --run ID [--pid N] [--json]; --pid is for begin."

  /// Digits only, above 1, a live process, and one this user owns.
  public static func validate(pid text: String, pids: AgentPIDs = .system) throws -> Int32 {
    guard !text.isEmpty, text.utf8.count <= 10, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
      let value = Int32(text), value > 1
    else {
      throw InputError("--pid must be the numeric ID of your agent process.")
    }
    guard pids.owner(value) == pids.uid() else {
      throw InputError("--pid must be a running process you own.")
    }
    return value
  }

  public static func validate(agent: String, run: String) throws {
    func ok(_ value: String, limit: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= limit
        && value.utf8.allSatisfy {
          ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
            || $0 == 0x2D || $0 == 0x5F
        }
    }
    guard ok(agent, limit: 32) else {
      throw InputError("--agent must be 1-32 letters, digits, hyphens or underscores.")
    }
    guard ok(run, limit: 64) else {
      throw InputError("--run must be 1-64 letters, digits, hyphens or underscores.")
    }
  }

  /// `arguments` is the full argument list, starting with `agent`.
  public static func parse(_ arguments: [String], pids: AgentPIDs = .system) throws -> AgentCommand
  {
    guard arguments.count >= 2, let verb = Verb(rawValue: arguments[1]) else {
      throw InputError(usage)
    }
    var agent: String?
    var run: String?
    var pid: Int32?
    var json = false
    var index = 2
    while index < arguments.count {
      let flag = arguments[index]
      index += 1
      switch flag {
      case "--json":
        guard !json else { throw InputError("Unknown or repeated option: \(flag)") }
        json = true
      case "--pid":
        guard verb == .begin, pid == nil, index < arguments.count else {
          throw InputError("Unknown or repeated option: \(flag)")
        }
        pid = try validate(pid: arguments[index], pids: pids)
        index += 1
      case "--agent", "--run":
        guard index < arguments.count else { throw InputError("Missing value for \(flag).") }
        let value = arguments[index]
        index += 1
        if flag == "--agent" {
          guard agent == nil else { throw InputError("Unknown or repeated option: \(flag)") }
          agent = value
        } else {
          guard run == nil else { throw InputError("Unknown or repeated option: \(flag)") }
          run = value
        }
      default: throw InputError("Unknown or repeated option: \(flag)")
      }
    }
    guard let agent, let run else { throw InputError(usage) }
    try validate(agent: agent, run: run)
    return AgentCommand(verb: verb, agent: agent, run: run, json: json, pid: pid)
  }
}

public struct AgentRunRecord: Codable, Equatable, Sendable {
  public var holdID: UUID
  public var lastRenew: Date
  /// The detached renewer for this run, with its start time so a recycled pid isn't mistaken for it.
  public var renewerPID: Int32?
  public var renewerStartMicros: Int64?
  public var hookRenewUntil: Date?

  public init(
    holdID: UUID, lastRenew: Date, renewerPID: Int32? = nil, renewerStartMicros: Int64? = nil,
    hookRenewUntil: Date? = nil
  ) {
    self.holdID = holdID
    self.lastRenew = lastRenew
    self.renewerPID = renewerPID
    self.renewerStartMicros = renewerStartMicros
    self.hookRenewUntil = hookRenewUntil
  }
}

public struct AgentLifecycle {
  public static let leaseSeconds: TimeInterval = 600
  public static let hookQuietSeconds: TimeInterval = 3600
  public let directory: URL
  /// Sends one request to the app, launching it first when the caller wants that.
  public let transport: (ControlRequest) async throws -> ControlResponse
  public let pids: AgentPIDs
  /// Starts a detached renewer for a run and returns its pid. Nil means `--pid` starts nothing.
  public let spawnRenewer: (@Sendable (AgentCommand, Int32) throws -> Int32)?

  public init(
    stateDirectory: URL, pids: AgentPIDs = .system,
    spawnRenewer: (@Sendable (AgentCommand, Int32) throws -> Int32)? = nil,
    transport: @escaping (ControlRequest) async throws -> ControlResponse
  ) {
    self.directory = stateDirectory.appendingPathComponent("agents", isDirectory: true)
    self.pids = pids
    self.spawnRenewer = spawnRenewer
    self.transport = transport
  }

  /// The saved record for a run, if any. The renewer uses it to notice `end`.
  public func currentRecord(for command: AgentCommand) -> AgentRunRecord? { load(command) }

  private func file(_ command: AgentCommand, suffix: String = "json") -> URL {
    directory.appendingPathComponent("\(command.agent).\(command.run).\(suffix)")
  }

  private func load(_ command: AgentCommand) -> AgentRunRecord? {
    guard let data = try? Data(contentsOf: file(command)), data.count <= 4096 else { return nil }
    return try? WireJSON.decode(AgentRunRecord.self, from: data)
  }

  private func save(_ record: AgentRunRecord, for command: AgentCommand) throws {
    let url = file(command)
    try PrivateFile.write(try WireJSON.encode(record), to: url)
  }

  private func clear(_ command: AgentCommand) {
    try? FileManager.default.removeItem(at: file(command))
  }

  /// Serializes concurrent hooks for one run. Held for the whole command, including socket calls.
  private nonisolated(nonsending) func locked<T>(
    _ command: AgentCommand, _ body: () async throws -> T
  ) async throws -> T {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = file(command, suffix: "lock").path
    var descriptor: Int32 = -1
    // pruneStale may unlink a lock file between our open and flock. Re-check the path still
    // names the inode we locked, or two runs could hold "the same" lock on different files.
    for _ in 0..<5 {
      let candidate = open(path, O_CREAT | O_RDWR, 0o600)
      guard candidate >= 0 else { throw InputError("Couldn't open the agent run lock.") }
      guard flock(candidate, LOCK_EX) == 0 else {
        close(candidate)
        throw InputError("Couldn't lock the agent run state.")
      }
      var held = stat()
      var named = stat()
      if fstat(candidate, &held) == 0, stat(path, &named) == 0, held.st_ino == named.st_ino,
        held.st_dev == named.st_dev
      {
        descriptor = candidate
        break
      }
      flock(candidate, LOCK_UN)
      close(candidate)
    }
    guard descriptor >= 0 else { throw InputError("Couldn't lock the agent run state.") }
    defer { close(descriptor) }
    defer { flock(descriptor, LOCK_UN) }
    return try await body()
  }

  private nonisolated(nonsending) func lease(_ command: AgentCommand, id: UUID?) async throws
    -> ControlResponse
  {
    if let id {
      return try await transport(
        ControlRequest(action: .renew, id: id, duration: Self.leaseSeconds))
    }
    return try await transport(
      ControlRequest(
        action: .lease,
        label: command.decidedByHook
          ? "Agent \(command.agent) · decided by: hook" : "Agent \(command.agent)",
        duration: Self.leaseSeconds))
  }

  private static let ended = ControlResponse(
    ok: false, message: WakeError.holdNotFound.localizedDescription,
    code: WakeError.holdNotFound.rawValue)

  /// Called under the run lock after a successful `begin --pid`. One renewer per run: a recorded
  /// renewer that's alive with its start time unchanged is kept. A spawn failure leaves the lease
  /// to its TTL rather than failing the begin.
  private func ensureRenewer(_ command: AgentCommand) {
    guard let agentPID = command.pid, let spawnRenewer, var record = load(command) else { return }
    if let existing = record.renewerPID, let started = record.renewerStartMicros,
      pids.startMicros(existing) == started
    {
      return
    }
    guard let child = try? spawnRenewer(command, agentPID),
      let started = pids.startMicros(child)
    else { return }
    record.renewerPID = child
    record.renewerStartMicros = started
    try? save(record, for: command)
  }

  /// Records and lock files untouched this long belong to runs that are long gone.
  public static let staleSeconds: TimeInterval = 86_400

  /// Removes agent state for dead runs. A record goes when it is older than `staleSeconds` and
  /// its renewer isn't alive; a lock file goes when it has no record, is that old, and nobody
  /// holds it. `keeping` is the current run's files. Best effort: failures leave files behind.
  public func pruneStale(now: Date = Date(), keeping: AgentCommand? = nil) {
    let fm = FileManager.default
    guard
      let urls = try? fm.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let keep = Set(
      keeping.map { [file($0).lastPathComponent, file($0, suffix: "lock").lastPathComponent] }
        ?? [])
    func age(_ url: URL) -> TimeInterval {
      let date =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? now
      return now.timeIntervalSince(date)
    }
    /// True when the record at `url` is old, unrenewed and has no live renewer.
    func staleRecord(_ url: URL) -> Bool {
      guard age(url) > Self.staleSeconds,
        let data = try? Data(contentsOf: url), data.count <= 4096,
        let record = try? WireJSON.decode(AgentRunRecord.self, from: data),
        now.timeIntervalSince(record.lastRenew) > Self.staleSeconds
      else { return false }
      if let pid = record.renewerPID, let started = record.renewerStartMicros,
        pids.startMicros(pid) == started
      {
        return false
      }
      return true
    }
    /// Runs `body` while holding the lock at `url` without blocking, only if the path still names
    /// the inode that was locked. A busy or replaced lock skips the body.
    func tryLocked(_ url: URL, create: Bool, _ body: () -> Void) {
      let descriptor = open(url.path, create ? O_CREAT | O_RDWR : O_RDWR, 0o600)
      guard descriptor >= 0 else { return }
      defer { close(descriptor) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
      defer { flock(descriptor, LOCK_UN) }
      var held = stat()
      var named = stat()
      guard fstat(descriptor, &held) == 0, stat(url.path, &named) == 0,
        held.st_ino == named.st_ino, held.st_dev == named.st_dev
      else { return }
      body()
    }
    for url in urls where !keep.contains(url.lastPathComponent) {
      switch url.pathExtension {
      case "json":
        guard staleRecord(url) else { continue }
        // A begin for that run may save a fresh record between the read and the removal, so take
        // its lock (never blocking: two begins pruning each other's records must not deadlock)
        // and check again before removing.
        let lock = url.deletingPathExtension().appendingPathExtension("lock")
        tryLocked(lock, create: true) {
          if staleRecord(url) { try? fm.removeItem(at: url) }
        }
      case "lock":
        let record = url.deletingPathExtension().appendingPathExtension("json")
        guard age(url) > Self.staleSeconds, !fm.fileExists(atPath: record.path) else { continue }
        tryLocked(url, create: false) { try? fm.removeItem(at: url) }
      default: continue
      }
    }
  }

  public nonisolated(nonsending) func run(_ command: AgentCommand, now: Date = Date()) async throws
    -> ControlResponse
  {
    try await locked(command) {
      if command.verb == .begin { pruneStale(now: now, keeping: command) }
      switch command.verb {
      case .begin:
        if let record = load(command) {
          let renewed = try await lease(command, id: record.holdID)
          if renewed.ok {
            var updated = record
            updated.lastRenew = now
            if command.decidedByHook {
              updated.hookRenewUntil = now.addingTimeInterval(Self.hookQuietSeconds)
            }
            try save(updated, for: command)
            ensureRenewer(command)
            return ControlResponse(ok: true, id: record.holdID)
          }
          // Paused or any other refusal leaves things alone. Only an ended ID starts a new hold.
          guard renewed.code == WakeError.holdNotFound.rawValue else { return renewed }
          clear(command)
        }
        let started = try await lease(command, id: nil)
        guard started.ok, let id = started.id else { return started }
        try save(
          AgentRunRecord(
            holdID: id, lastRenew: now,
            hookRenewUntil: command.decidedByHook
              ? now.addingTimeInterval(Self.hookQuietSeconds) : nil),
          for: command)
        ensureRenewer(command)
        return ControlResponse(ok: true, id: id)
      case .renew:
        guard let record = load(command) else { return Self.ended }
        if !command.decidedByHook, let deadline = record.hookRenewUntil, now >= deadline {
          return Self.ended
        }
        let renewed = try await lease(command, id: record.holdID)
        if renewed.ok {
          var updated = record
          updated.lastRenew = now
          if command.decidedByHook {
            updated.hookRenewUntil = now.addingTimeInterval(Self.hookQuietSeconds)
          }
          try save(updated, for: command)
          ensureRenewer(command)
          return ControlResponse(ok: true, id: record.holdID)
        }
        if renewed.code == WakeError.holdNotFound.rawValue { clear(command) }
        return renewed
      case .end:
        guard let record = load(command) else {
          return ControlResponse(ok: true, message: "No active hold for this run.")
        }
        let released: ControlResponse
        do {
          released = try await transport(ControlRequest(action: .release, id: record.holdID))
        } catch is AppConnectionUnavailable {
          // A closed app holds nothing: relaunch drops lease holds, so the record is stale.
          clear(command)
          return ControlResponse(ok: true, message: "Released.")
        }
        guard released.ok || released.code == WakeError.holdNotFound.rawValue else {
          return released
        }
        clear(command)
        return ControlResponse(ok: true, message: "Released.")
      }
    }
  }
}
