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
  private static func run(_ process: Process) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      process.terminationHandler = { _ in continuation.resume() }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  private static func exited(_ process: Process) async {
    while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func processLaunchErrorsAreReported() async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/nonexistent/dilated-inspection")
    await #expect(throws: (any Error).self) { try await Self.run(process) }
  }

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
    begin.environment = [
      "DILATED_STATE_DIR": state.path,
      "LLVM_PROFILE_FILE": executable.deletingLastPathComponent()
        .appendingPathComponent("codecov/agent-cli-%p.profraw").path,
    ]
    // Our own pipe, never the test runner's, so the renewer can't hold CI's log open. The
    // renewer's stdio goes to /dev/null, so the pipe closes when begin exits.
    let output = Pipe()
    begin.standardOutput = output
    begin.standardError = output
    // Awaited without blocking a thread: the socket server answers from the cooperative pool,
    // and a test thread parked in waitUntilExit can starve it on a small CI runner, so begin
    // times out reading the reply.
    try await Self.run(begin)
    let printed = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(begin.terminationStatus == 0, "dilated agent begin printed: \(printed)")
    #expect(app.holdCount == 1)

    let record = try WireJSON.decode(
      AgentRunRecord.self,
      from: Data(contentsOf: state.appendingPathComponent("agents/claude.proc1.json")))
    let child = try #require(record.renewerPID)
    renewer = child
    #expect(ProcessStartTime.micros(pid: child) == record.renewerStartMicros)
    // Its own session, so it outlives the hook that started it.
    #expect(getsid(child) == child)
    let descriptors = Process()
    descriptors.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    descriptors.arguments = ["-a", "-p", String(child), "-Fn"]
    let listing = Pipe()
    descriptors.standardOutput = listing
    descriptors.standardError = FileHandle.nullDevice
    try await Self.run(descriptors)
    try #require(descriptors.terminationStatus == 0, "lsof inspection failed.")
    let files = String(decoding: listing.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(!files.isEmpty, "lsof returned no descriptor listing.")
    #expect(
      !files.contains(state.appendingPathComponent("agents/claude.proc1.lock").path),
      "The renewer inherited its parent's open descriptor.")

    kill(agent.processIdentifier, SIGKILL)
    await Self.exited(agent)
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
