import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

/// The app: the real router over a real engine, with a clock the test moves.
private final class RenewerApp: @unchecked Sendable {
  private let lock = NSLock()
  private var engine = WakeEngine()
  private var clock = Date(timeIntervalSince1970: 1_800_000_000)
  private var log: [ControlRequest] = []
  var unavailable = false
  private(set) var attempts = 0

  var now: Date { lock.withLock { clock } }
  var requests: [ControlRequest] { lock.withLock { log } }
  var renewCount: Int { requests.filter { $0.action == .renew }.count }
  var holdCount: Int {
    lock.withLock {
      engine.tick(now: clock)
      return engine.holds.count
    }
  }
  func advance(_ seconds: TimeInterval) { lock.withLock { clock.addTimeInterval(seconds) } }
  func stopAll() { lock.withLock { engine.stopAll(now: clock) } }

  func send(_ request: ControlRequest) throws -> ControlResponse {
    try lock.withLock {
      attempts += 1
      if unavailable { throw AppConnectionUnavailable(text: "Start the app first") }
      log.append(request)
      return ControlRouter.handle(request, engine: &engine, now: clock)
    }
  }
}

/// Pids the test can kill, and a hand-driven timer and exit watch standing in for dispatch.
private final class RenewerWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var alive: Set<Int32> = []
  private var exitHandler: (@Sendable () -> Void)?
  private var tickHandler: (@Sendable () -> Void)?
  private(set) var tickInterval: Duration?
  var uid: uid_t = 501
  var owners: [Int32: uid_t] = [:]

  func spawn(_ pid: Int32) { lock.withLock { _ = alive.insert(pid) } }
  func kill(_ pid: Int32) {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      alive.remove(pid)
      return exitHandler
    }
    handler?()
  }

  var pids: AgentPIDs {
    AgentPIDs(
      startMicros: { pid in
        self.lock.withLock { self.alive.contains(pid) ? 7_000 + Int64(pid) : nil }
      },
      owner: { pid in self.lock.withLock { self.owners[pid] } },
      uid: { self.uid })
  }

  func makeTicker() -> @Sendable (Duration, @escaping @Sendable () -> Void) -> @Sendable () -> Void
  {
    { interval, handler in
      self.lock.withLock {
        self.tickInterval = interval
        self.tickHandler = handler
      }
      return { self.lock.withLock { self.tickHandler = nil } }
    }
  }

  func makeOnExit()
    -> @Sendable (Int32, Int64, @escaping @Sendable () -> Void) -> @Sendable () -> Void
  {
    { _, _, handler in
      self.lock.withLock { self.exitHandler = handler }
      return { self.lock.withLock { self.exitHandler = nil } }
    }
  }

  var registered: Bool { lock.withLock { tickHandler != nil && exitHandler != nil } }
  func tick() { lock.withLock { tickHandler }?() }
}

private func settle(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<400 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

private final class RenewerRig: @unchecked Sendable {
  let app = RenewerApp()
  let world = RenewerWorld()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("agent-renewer-\(UUID().uuidString)")
  let agentPID: Int32 = 4242
  let spawned = SpawnLog()

  final class SpawnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(agent: String, run: String, pid: Int32)] = []
    var count: Int { lock.withLock { all.count } }
    func add(_ agent: String, _ run: String, _ pid: Int32) {
      lock.withLock { all.append((agent, run, pid)) }
    }
  }

  init() { world.spawn(agentPID) }

  func lifecycle(spawning: Bool = false) -> AgentLifecycle {
    let app = app
    let world = world
    let spawned = spawned
    let spawner: @Sendable (AgentCommand, Int32) throws -> Int32 = { command, pid in
      spawned.add(command.agent, command.run, pid)
      let child = 5000 + Int32(spawned.count)
      world.spawn(child)
      return child
    }
    return AgentLifecycle(
      stateDirectory: directory, pids: world.pids, spawnRenewer: spawning ? spawner : nil
    ) { try app.send($0) }
  }

  func command(_ verb: AgentCommand.Verb, pid: Int32? = nil) -> AgentCommand {
    AgentCommand(verb: verb, agent: "claude", run: "r1", json: false, pid: pid)
  }

  func renewer() -> AgentRenewer {
    let app = app
    return AgentRenewer(
      agent: "claude", run: "r1", pid: agentPID, lifecycle: lifecycle(), pids: world.pids,
      now: { app.now }, ticker: world.makeTicker(), onExit: world.makeOnExit())
  }

  /// Runs the renewer on a task and waits until its timer and exit watch are registered.
  func start() async -> Task<AgentRenewer.Exit, Never> {
    let task = Task { await self.renewer().run() }
    _ = await settle { self.world.registered }
    return task
  }

  func tickAndWait(renewals expected: Int) async -> Bool {
    app.advance(120)
    world.tick()
    return await settle { self.app.renewCount == expected }
  }
}

struct AgentRenewerTests {
  @Test func renewsEveryTwoMinutesWhileThePidIsAlive() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    #expect(rig.world.tickInterval == .seconds(120))
    #expect(AgentRenewer.interval == .seconds(120))
    for expected in 1...3 {
      #expect(await rig.tickAndWait(renewals: expected))
    }
    #expect(rig.app.holdCount == 1)
    rig.world.kill(rig.agentPID)
    #expect(await task.value == .agentExited)
  }

  @Test func stopsRenewingOnceEndRemovesTheRecord() async throws {
    let rig = RenewerRig()
    let lifecycle = rig.lifecycle()
    _ = try await lifecycle.run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    #expect(await rig.tickAndWait(renewals: 1))
    _ = try await lifecycle.run(rig.command(.end), now: rig.app.now)
    rig.app.advance(120)
    rig.world.tick()
    #expect(await task.value == .recordGone)
    #expect(rig.app.renewCount == 1)
    #expect(rig.app.holdCount == 0)
  }

  @Test func stopsRenewingOnceThePidExits() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    #expect(await rig.tickAndWait(renewals: 1))
    rig.world.kill(rig.agentPID)
    #expect(await task.value == .agentExited)
    #expect(rig.app.renewCount == 1)
  }

  @Test func aTickAfterTheAgentVanishedRenewsNothing() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    // The pid is gone and a tick lands before the exit event does.
    rig.world.kill(rig.agentPID)
    rig.world.tick()
    #expect(await task.value == .agentExited)
    #expect(rig.app.renewCount == 0)
  }

  @Test func exitsWhenTheHoldIsNotFound() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    // Past the TTL the app has dropped the hold, so the renew comes back not-found.
    rig.app.advance(601)
    rig.world.tick()
    #expect(await task.value == .holdEnded)
    #expect(rig.app.requests.filter { $0.action == .lease }.count == 1)
    #expect(rig.app.holdCount == 0)
  }

  @Test func exitsWhenAutomationIsPausedAndCreatesNothing() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    rig.app.stopAll()
    rig.world.tick()
    #expect(await task.value == .holdEnded)
    #expect(rig.app.holdCount == 0)
    #expect(rig.app.requests.filter { $0.action == .lease }.count == 1)
  }

  @Test func exitsAfterTheAppIsUnavailableTwiceInARow() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    let base = rig.app.attempts
    rig.app.unavailable = true
    rig.world.tick()
    // One miss is tolerated, and a success in between resets the count.
    #expect(await settle { rig.app.attempts == base + 1 })
    rig.app.unavailable = false
    #expect(await rig.tickAndWait(renewals: 1))
    rig.app.unavailable = true
    rig.world.tick()
    #expect(await settle { rig.app.attempts == base + 3 })
    rig.world.tick()
    #expect(await task.value == .appUnavailable)
  }

  @Test func noSecondRenewerOnADuplicateBegin() async throws {
    let rig = RenewerRig()
    let lifecycle = rig.lifecycle(spawning: true)
    let begin = rig.command(.begin, pid: rig.agentPID)
    let first = try await lifecycle.run(begin, now: rig.app.now)
    let second = try await lifecycle.run(begin, now: rig.app.now)
    #expect(first.ok && second.ok && first.id == second.id)
    #expect(rig.spawned.count == 1)
    let record = try #require(lifecycle.currentRecord(for: begin))
    #expect(record.renewerPID == 5001 && record.renewerStartMicros == 7_000 + 5001)
    // A renew keeps the renewer on the record.
    _ = try await lifecycle.run(rig.command(.renew), now: rig.app.now)
    #expect(lifecycle.currentRecord(for: begin)?.renewerPID == 5001)
    // Once the recorded renewer is gone, the next begin starts a replacement.
    rig.world.kill(5001)
    _ = try await lifecycle.run(begin, now: rig.app.now)
    #expect(rig.spawned.count == 2)
    #expect(lifecycle.currentRecord(for: begin)?.renewerPID == 5002)
  }

  @Test func beginWithoutAPidStartsNoRenewer() async throws {
    let rig = RenewerRig()
    let lifecycle = rig.lifecycle(spawning: true)
    _ = try await lifecycle.run(rig.command(.begin), now: rig.app.now)
    #expect(rig.spawned.count == 0)
    #expect(lifecycle.currentRecord(for: rig.command(.begin))?.renewerPID == nil)
  }

  @Test func theLeaseLapsesWithinOneTTLAfterTheAgentIsKilled() async throws {
    let rig = RenewerRig()
    _ = try await rig.lifecycle().run(rig.command(.begin), now: rig.app.now)
    let task = await rig.start()
    for expected in 1...5 { #expect(await rig.tickAndWait(renewals: expected)) }
    #expect(rig.app.holdCount == 1)
    // SIGKILL: no hook runs, so only the exit watch tells the renewer.
    rig.world.kill(rig.agentPID)
    #expect(await task.value == .agentExited)
    rig.app.advance(AgentLifecycle.leaseSeconds - 1)
    #expect(rig.app.holdCount == 1)
    rig.app.advance(2)
    #expect(rig.app.holdCount == 0)
  }

  @Test func pidValidationRejectsBadInput() throws {
    let world = RenewerWorld()
    world.owners = [4242: 501, 777: 0, 888: 502]
    let pids = world.pids
    func parse(_ pid: String) throws -> AgentCommand {
      try AgentCommand.parse(
        ["agent", "begin", "--agent", "claude", "--run", "r1", "--pid", pid], pids: pids)
    }
    #expect(try parse("4242").pid == 4242)
    for bad in [
      "", "abc", "12a", "-5", "+5", " 42", "4.2", "0", "00", "1", "01", "99999999999",
      "4294967296", "777", "888", "31337",
    ] {
      #expect(throws: (any Error).self) { try parse(bad) }
    }
    #expect(throws: (any Error).self) {
      try AgentCommand.parse(
        ["agent", "begin", "--agent", "a", "--run", "r", "--pid", "4242", "--pid", "4242"],
        pids: pids)
    }
    #expect(throws: (any Error).self) {
      try AgentCommand.parse(
        ["agent", "begin", "--agent", "a", "--run", "r", "--pid"], pids: pids)
    }
    for verb in ["renew", "end"] {
      #expect(throws: (any Error).self) {
        try AgentCommand.parse(
          ["agent", verb, "--agent", "a", "--run", "r", "--pid", "4242"], pids: pids)
      }
    }
    // The real process table: this process is ours, pid 1 is launchd's.
    let mine = try AgentCommand.parse(
      ["agent", "begin", "--agent", "a", "--run", "r", "--pid", String(getpid())])
    #expect(mine.pid == getpid())
    #expect(throws: (any Error).self) {
      try AgentCommand.parse(["agent", "begin", "--agent", "a", "--run", "r", "--pid", "1"])
    }
  }

  @Test func theHiddenRenewerCommandParsesAndStaysOutOfHelp() throws {
    let arguments = AgentRenewerCommand.arguments(agent: "claude", run: "r1", pid: 4242)
    #expect(AgentRenewerCommand.matches(arguments))
    let launch = try AgentRenewerCommand.parse(arguments)
    #expect(launch.agent == "claude" && launch.run == "r1" && launch.pid == 4242)
    #expect(throws: (any Error).self) {
      try AgentRenewerCommand.parse(["agent", "_renew", "--agent", "a", "--run", "r", "--pid", "1"])
    }
    #expect(throws: (any Error).self) { try AgentRenewerCommand.parse(["agent", "_renew"]) }
    #expect(!AgentRenewerCommand.matches(["agent", "begin", "--agent", "a", "--run", "r"]))
    #expect(throws: (any Error).self) { try AgentCommand.parse(arguments) }
  }
}
