import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

private final class AdapterAnchor {}
private final class AdapterApp: @unchecked Sendable {
  private let lock = NSLock()
  private var engine = WakeEngine()
  func send(_ request: ControlRequest) -> ControlResponse {
    lock.withLock { ControlRouter.handle(request, engine: &engine) }
  }
  var labels: [String] { lock.withLock { engine.holds.map(\.label) } }
}

struct AgentAdapterProcessTests {
  @Test func codexInterruptEndsOnlyItsOwnQuietHold() async throws {
    let executable = Bundle(for: AdapterAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("dilated")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "adapter-process-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let app = AdapterApp()
    let server = try LocalSocketServer(endpoint: .init(stateDirectory: directory)) { app.send($0) }
    var children: [AgentRunRecord] = []
    defer {
      for record in children {
        if let pid = record.renewerPID,
          AgentPIDs.system.startMicros(pid) == record.renewerStartMicros
        {
          kill(pid, SIGTERM)
        }
      }
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    func invoke(_ agent: String, _ event: String) async throws {
      let child = Process()
      child.executableURL = executable
      child.arguments = [
        "agent", agent + "-hook", "--pid", String(ProcessInfo.processInfo.processIdentifier),
      ]
      child.environment = ["DILATED_STATE_DIR": directory.path]
      let input = Pipe()
      let output = Pipe()
      child.standardInput = input
      child.standardOutput = output
      child.standardError = output
      try input.fileHandleForWriting.write(
        contentsOf: JSONSerialization.data(withJSONObject: [
          "session_id": "shared-run", "hook_event_name": event,
        ]))
      try input.fileHandleForWriting.close()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        child.terminationHandler = { _ in continuation.resume() }
        do { try child.run() } catch { continuation.resume(throwing: error) }
      }
      #expect(child.terminationStatus == 0)
      #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
      let record = directory.appendingPathComponent("agents/\(agent).shared-run.json")
      if let data = try? Data(contentsOf: record) {
        children.append(try WireJSON.decode(AgentRunRecord.self, from: data))
      }
    }
    try await invoke("codex", "UserPromptSubmit")
    #expect(app.labels == ["Agent codex · decided by: hook"])
    try await invoke("claude", "UserPromptSubmit")
    try await invoke("opencode", "UserPromptSubmit")
    #expect(app.labels.count == 3)
    try await invoke("codex", "Interrupt")
    #expect(app.labels.count == 2)
    try await invoke("opencode", "Stop")
    #expect(app.labels == ["Agent claude · decided by: hook"])
    try await invoke("claude", "Stop")
    #expect(app.labels.isEmpty)
  }
}
