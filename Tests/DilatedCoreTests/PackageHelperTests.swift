import Foundation
import Testing

@testable import DilatedCore

struct PackageHelperTests {
  @Test func processCheckRefusesARunningAppEvenWhenWorkspaceCannotSeeIt() async throws {
    let executable = URL(
      fileURLWithPath: "/tmp/Dilated [check]-\(UUID().uuidString).app/Contents/MacOS/DilatedApp")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "exec -a \"$1\" /bin/sleep 10", "package-check-test", executable.path,
    ]
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
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
    process.terminate()
    process.waitUntilExit()
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
