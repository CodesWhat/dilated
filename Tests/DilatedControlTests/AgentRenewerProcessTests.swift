import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

private final class BundleAnchor {}

/// An engine behind a lock, answering the real socket protocol like the app does.
private final class SocketApp: @unchecked Sendable {
  private let lock = NSLock()
  private var engine = WakeEngine()
  func handle(_ request: ControlRequest) -> ControlResponse {
    lock.withLock { ControlRouter.handle(request, engine: &engine) }
  }
  var holdCount: Int { lock.withLock { engine.holds.count } }
}

/// Runs the real `dilated` executable, built next to the test bundle, against a socket server in
/// this process. The agent is a `sleep` child that the test kills.
struct AgentRenewerProcessTests {
  @Test func theDetachedRenewerExitsWhenTheAgentProcessDies() async throws {
    let executable = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("dilated")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))
    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("renewer-proc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let app = SocketApp()
    let server = try LocalSocketServer(endpoint: SocketEndpoint(stateDirectory: state)) {
      app.handle($0)
    }

    let agent = Process()
    agent.executableURL = URL(fileURLWithPath: "/bin/sleep")
    agent.arguments = ["30"]
    agent.standardOutput = FileHandle.nullDevice
    agent.standardError = FileHandle.nullDevice
    try agent.run()
    var renewer: pid_t?
    defer {
      if let renewer { kill(renewer, SIGKILL) }
      if agent.isRunning { agent.terminate() }
      server.stop()
      try? FileManager.default.removeItem(at: state)
    }

    let begin = Process()
    begin.executableURL = executable
    begin.arguments = [
      "agent", "begin", "--agent", "claude", "--run", "proc1", "--pid",
      String(agent.processIdentifier),
    ]
    begin.environment = ["DILATED_STATE_DIR": state.path]
    // Never inherit the test runner's output pipe, or the renewer holds CI's log open.
    begin.standardOutput = FileHandle.nullDevice
    begin.standardError = FileHandle.nullDevice
    try begin.run()
    begin.waitUntilExit()
    #expect(begin.terminationStatus == 0)
    #expect(app.holdCount == 1)

    let record = try WireJSON.decode(
      AgentRunRecord.self,
      from: Data(contentsOf: state.appendingPathComponent("agents/claude.proc1.json")))
    let child = try #require(record.renewerPID)
    renewer = child
    #expect(ProcessStartTime.micros(pid: child) == record.renewerStartMicros)
    // Its own session, so it outlives the hook that started it.
    #expect(getsid(child) == child)

    kill(agent.processIdentifier, SIGKILL)
    agent.waitUntilExit()
    var gone = false
    for _ in 0..<100 {
      if ProcessStartTime.micros(pid: child) == nil {
        gone = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(gone)
    // Exiting never releases: the hold lapses on its own TTL.
    #expect(app.holdCount == 1)
  }
}
