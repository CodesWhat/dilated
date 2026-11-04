import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

private final class HookBundleAnchor {}
private final class HookSocketApp: @unchecked Sendable {
  private let lock = NSLock()
  private var engine = WakeEngine()
  func send(_ request: ControlRequest) -> ControlResponse {
    lock.withLock { ControlRouter.handle(request, engine: &engine) }
  }
  var labels: [String] { lock.withLock { engine.holds.map(\.label) } }
}

struct ClaudeHookProcessTests {
  @Test func realCLIProcessesBeginRenewStopAndMalformedInputQuietly() async throws {
    let executable = Bundle(for: HookBundleAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("dilated")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hook-process-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let alias = directory.appendingPathComponent("Dilated's CLI")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
    let installation = ClaudeHookInstallation(
      settingsURL: directory.appendingPathComponent("settings.json"), executable: alias)
    try installation.install()
    let settings = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: installation.settingsURL))
        as? [String: Any])
    let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
    let handlers = try #require(hooks["UserPromptSubmit"]?.first?["hooks"] as? [[String: Any]])
    let shellCommand = try #require(handlers.first?["command"] as? String)
    let app = HookSocketApp()
    let server = try LocalSocketServer(endpoint: .init(stateDirectory: directory)) { app.send($0) }
    var child: Int32?
    defer {
      if let child { kill(child, SIGTERM) }
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    func invoke(_ payload: String) async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", shellCommand]
      process.environment = ["DILATED_STATE_DIR": directory.path]
      let input = Pipe()
      let output = Pipe()
      process.standardInput = input
      process.standardOutput = output
      process.standardError = output
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
          input.fileHandleForWriting.write(Data(payload.utf8))
          try input.fileHandleForWriting.close()
        } catch { continuation.resume(throwing: error) }
      }
      #expect(process.terminationStatus == 0)
      #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
    try await invoke(#"{"session_id":"process-test","hook_event_name":"UserPromptSubmit"}"#)
    #expect(app.labels == ["Agent claude · decided by: hook"])
    let record = try WireJSON.decode(
      AgentRunRecord.self,
      from: Data(contentsOf: directory.appendingPathComponent("agents/claude.process-test.json")))
    child = try #require(record.renewerPID)
    try await invoke(#"{"session_id":"process-test","hook_event_name":"PreToolUse"}"#)
    #expect(app.labels.count == 1)
    _ = app.send(ControlRequest(action: .stopAll))
    try await invoke(#"{"session_id":"process-test","hook_event_name":"UserPromptSubmit"}"#)
    #expect(app.labels.isEmpty)
    try await invoke(#"{"session_id":"process-test","hook_event_name":"Stop"}"#)
    try await invoke("invalid JSON")
    #expect(app.labels.isEmpty)
  }
}
