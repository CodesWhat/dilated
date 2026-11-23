import Darwin
import Foundation
import Testing

@testable import DilatedCore

struct PackageHelperTests {
  /// Ends the child without `waitUntilExit`, which parks a cooperative thread on a run loop that
  /// can miss the exit and never return. Polls `isRunning` under a deadline, escalating to
  /// SIGKILL, and fails the test instead of hanging when the child will not go.
  private static func stop(_ process: Process) async throws {
    process.terminate()
    let grace = ContinuousClock.now.advanced(by: .seconds(2))
    while process.isRunning && ContinuousClock.now < grace {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    let reap = ContinuousClock.now.advanced(by: .seconds(5))
    while process.isRunning && ContinuousClock.now < reap {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!process.isRunning, "The child did not exit after SIGKILL.")
  }

  @Test func processCheckRefusesARunningAppEvenWhenWorkspaceCannotSeeIt() async throws {
    let executable = URL(
      fileURLWithPath: "/tmp/Dilated [check]-\(UUID().uuidString).app/Contents/MacOS/DilatedApp")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "exec -a \"$1\" /bin/sleep 120", "package-check-test", executable.path,
    ]
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    let pattern = "^" + NSRegularExpression.escapedPattern(for: executable.path) + "($|[[:space:]])"
    var ready = false
    while ContinuousClock.now < deadline {
      let found = try await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
        arguments: ["-f", pattern], timeout: 0.5)
      if !found.timedOut, found.status == 0 {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(ready, "The child did not adopt the expected app identity.")
    await #expect(throws: (any Error).self) {
      try await PackageHelperCheck.verifyAppAbsent(executable: executable)
    }
    try await Self.stop(process)
    try await PackageHelperCheck.verifyAppAbsent(executable: executable)
  }

  @Test func onlyConfirmedAbsentServiceAndProcessAllowReplacement() throws {
    let missing = "Could not find service \"com.codeswhat.dilated.helper\" in domain for system"
    try PackageHelperCheck.validate(
      jobStatus: 113, jobError: missing, processStatus: 1, timedOut: false)
    for status: Int32 in [0, 1, 5, 112] {
      #expect(throws: (any Error).self) {
        try PackageHelperCheck.validate(
          jobStatus: status, jobError: missing, processStatus: 1, timedOut: false)
      }
    }
    for processStatus: Int32 in [0, 2, 3] {
      #expect(throws: (any Error).self) {
        try PackageHelperCheck.validate(
          jobStatus: 113, jobError: missing, processStatus: processStatus, timedOut: false)
      }
    }
    #expect(throws: (any Error).self) {
      try PackageHelperCheck.validate(
        jobStatus: 113, jobError: "unknown domain", processStatus: 1, timedOut: false)
    }
    #expect(throws: (any Error).self) {
      try PackageHelperCheck.validate(
        jobStatus: 113, jobError: missing, processStatus: 1, timedOut: true)
    }
  }
}
