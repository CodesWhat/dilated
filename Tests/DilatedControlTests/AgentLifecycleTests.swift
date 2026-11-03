import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

/// A stand-in for the app: the real router over a real engine, with a clock the test can move.
private final class FakeApp: @unchecked Sendable {
  var engine = WakeEngine()
  var clock = Date(timeIntervalSince1970: 1_800_000_000)
  var requests: [ControlRequest] = []
  func send(_ request: ControlRequest) -> ControlResponse {
    requests.append(request)
    return ControlRouter.handle(request, engine: &engine, now: clock)
  }
}

private final class Rig: @unchecked Sendable {
  let app = FakeApp()
  let directory: URL
  let lifecycle: AgentLifecycle
  init() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-lifecycle-\(UUID().uuidString)")
    self.directory = directory
    let app = app
    lifecycle = AgentLifecycle(stateDirectory: directory) { app.send($0) }
  }
  func run(_ verb: AgentCommand.Verb, agent: String = "claude", run: String) async throws
    -> ControlResponse
  {
    try await lifecycle.run(
      AgentCommand(verb: verb, agent: agent, run: run, json: false), now: app.clock)
  }
  func stateFiles() -> [String] {
    let names =
      (try? FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("agents").path)) ?? []
    return names.filter { $0.hasSuffix(".json") }
  }
}

struct AgentLifecycleTests {
  @Test func duplicateBeginReturnsTheSameHold() async throws {
    let rig = Rig()
    let first = try await rig.run(.begin, run: "r1")
    let second = try await rig.run(.begin, run: "r1")
    #expect(first.ok && second.ok)
    #expect(first.id != nil && first.id == second.id)
    #expect(rig.app.engine.holds.count == 1)
    #expect(rig.app.engine.holds.first?.source == .lease)
    #expect(rig.app.engine.holds.first?.expiry == rig.app.clock.addingTimeInterval(600))
  }

  @Test func renewKeepsTheHoldAndMovesTheDeadline() async throws {
    let rig = Rig()
    let started = try await rig.run(.begin, run: "r1")
    rig.app.clock.addTimeInterval(300)
    let renewed = try await rig.run(.renew, run: "r1")
    #expect(renewed.ok && renewed.id == started.id)
    #expect(rig.app.engine.holds.count == 1)
    #expect(rig.app.engine.holds.first?.expiry == rig.app.clock.addingTimeInterval(600))
  }

  @Test func endReleasesOnlyItsOwnRun() async throws {
    let rig = Rig()
    let a = try #require(try await rig.run(.begin, run: "runA").id)
    let b = try #require(try await rig.run(.begin, agent: "codex", run: "runB").id)
    let ended = try await rig.run(.end, run: "runA")
    #expect(ended.ok)
    #expect(rig.app.engine.holds.map(\.id) == [b])
    #expect(!rig.app.engine.holds.contains { $0.id == a })
    #expect(rig.app.engine.automationPaused == false)
    // A second end is a no-op and still leaves run B alone.
    let again = try await rig.run(.end, run: "runA")
    #expect(again.ok)
    #expect(rig.app.engine.holds.map(\.id) == [b])
  }

  @Test func renewAfterStopCreatesNothingAndReportsPaused() async throws {
    let rig = Rig()
    _ = try await rig.run(.begin, run: "r1")
    rig.app.engine.stopAll(now: rig.app.clock)
    let before = rig.app.requests.count
    let renewed = try await rig.run(.renew, run: "r1")
    #expect(!renewed.ok)
    #expect(renewed.code == WakeError.automationPaused.rawValue)
    #expect(renewed.message == WakeError.automationPaused.localizedDescription)
    #expect(rig.app.engine.holds.isEmpty)
    #expect(rig.app.requests.dropFirst(before).allSatisfy { $0.action == .renew })
    #expect(rig.app.requests.filter { $0.action == .lease }.count == 1)
  }

  @Test func renewAfterAnEndedIDCreatesNothingAndReportsEnded() async throws {
    let rig = Rig()
    _ = try await rig.run(.begin, run: "r1")
    rig.app.clock.addTimeInterval(601)
    let renewed = try await rig.run(.renew, run: "r1")
    #expect(!renewed.ok)
    #expect(renewed.code == WakeError.holdNotFound.rawValue)
    #expect(renewed.message == WakeError.holdNotFound.localizedDescription)
    #expect(rig.app.engine.holds.isEmpty)
    #expect(rig.app.requests.filter { $0.action == .lease }.count == 1)
    // The record is gone, so further renewals can't resurrect anything either.
    let later = try await rig.run(.renew, run: "r1")
    #expect(!later.ok && later.code == WakeError.holdNotFound.rawValue)
    #expect(rig.app.engine.holds.isEmpty)
    #expect(rig.stateFiles().isEmpty)
  }

  @Test func renewWithoutABeginCreatesNothing() async throws {
    let rig = Rig()
    let renewed = try await rig.run(.renew, run: "never-started")
    #expect(!renewed.ok && renewed.code == WakeError.holdNotFound.rawValue)
    #expect(rig.app.requests.isEmpty)
  }

  @Test func beginWithAnExpiredStateStartsAFreshHold() async throws {
    let rig = Rig()
    let old = try #require(try await rig.run(.begin, run: "r1").id)
    rig.app.clock.addTimeInterval(3600)
    let fresh = try await rig.run(.begin, run: "r1")
    #expect(fresh.ok)
    #expect(fresh.id != nil && fresh.id != old)
    #expect(rig.app.engine.holds.map(\.id) == [fresh.id!])
  }

  @Test func beginWithAnExpiredStateStaysDownWhileAutomationIsPaused() async throws {
    let rig = Rig()
    _ = try await rig.run(.begin, run: "r1")
    rig.app.clock.addTimeInterval(3600)
    rig.app.engine.stopAll(now: rig.app.clock)
    let refused = try await rig.run(.begin, run: "r1")
    #expect(!refused.ok)
    #expect(refused.code == WakeError.automationPaused.rawValue)
    #expect(rig.app.engine.holds.isEmpty)
    #expect(rig.app.requests.filter { $0.action == .lease }.count == 1)
  }

  @Test func beginWithoutAStateFileIsRefusedWhilePaused() async throws {
    let rig = Rig()
    rig.app.engine.stopAll(now: rig.app.clock)
    let refused = try await rig.run(.begin, run: "fresh")
    #expect(!refused.ok && refused.code == WakeError.automationPaused.rawValue)
    #expect(rig.app.engine.holds.isEmpty)
    #expect(rig.stateFiles().isEmpty)
  }

  @Test func stateRecordsHoldIDAndLastRenewUnderTheStateDirectory() async throws {
    let rig = Rig()
    let id = try #require(try await rig.run(.begin, run: "r1").id)
    let url = rig.directory.appendingPathComponent("agents/claude.r1.json")
    let record = try WireJSON.decode(AgentRunRecord.self, from: Data(contentsOf: url))
    #expect(record.holdID == id && record.lastRenew == rig.app.clock)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func concurrentBeginsForOneRunShareOneHold() async throws {
    let rig = Rig()
    let ids = try await withThrowingTaskGroup(of: UUID?.self) { group in
      for _ in 0..<4 {
        group.addTask { try await rig.run(.begin, run: "race").id }
      }
      var all: [UUID?] = []
      for try await id in group { all.append(id) }
      return all
    }
    #expect(Set(ids.compactMap { $0 }).count == 1)
    #expect(rig.app.engine.holds.count == 1)
  }

  @Test func parseAcceptsTheContractAndRejectsUnsafeNames() throws {
    let command = try AgentCommand.parse([
      "agent", "begin", "--agent", "claude", "--run", "a1B2-c_3", "--json",
    ])
    #expect(command.verb == .begin && command.agent == "claude" && command.run == "a1B2-c_3")
    #expect(command.json)
    #expect(try CLIInput.parse(["agent", "end", "--run", "x", "--agent", "y"]).agent?.verb == .end)
    let bad: [[String]] = [
      ["agent"], ["agent", "stop", "--agent", "a", "--run", "b"],
      ["agent", "begin", "--agent", "a"], ["agent", "begin", "--run", "b"],
      ["agent", "begin", "--agent", "../etc", "--run", "b"],
      ["agent", "begin", "--agent", "a", "--run", "b/c"],
      ["agent", "begin", "--agent", "a", "--run", ".."],
      ["agent", "begin", "--agent", "a.b", "--run", "c"],
      ["agent", "begin", "--agent", "", "--run", "c"],
      ["agent", "begin", "--agent", String(repeating: "a", count: 33), "--run", "c"],
      ["agent", "begin", "--agent", "a", "--run", String(repeating: "r", count: 65)],
      ["agent", "begin", "--agent", "a", "--agent", "b", "--run", "c"],
      ["agent", "begin", "--agent", "a", "--run", "c", "--ttl", "5m"],
      ["agent", "begin", "--agent", "a", "--run"],
    ]
    for arguments in bad {
      #expect(throws: (any Error).self) { try AgentCommand.parse(arguments) }
    }
    #expect(throws: Never.self) {
      try AgentCommand.validate(
        agent: String(repeating: "a", count: 32), run: String(repeating: "r", count: 64))
    }
  }
}
