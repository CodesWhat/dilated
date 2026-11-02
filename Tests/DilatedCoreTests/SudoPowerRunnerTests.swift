import Foundation
import Testing

@testable import DilatedCore

struct SudoPowerRunnerTests {
  @Test func theCommandIsExactlyTheSudoersRuleWithAbsolutePaths() {
    #expect(
      SudoPowerRunner.arguments(disabled: true)
        == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    #expect(
      SudoPowerRunner.arguments(disabled: false)
        == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    #expect(SudoPowerRunner.sudoPath == "/usr/bin/sudo")
  }

  @Test func sudoPermissionMessagesMapToPermissionUnavailable() async throws {
    for message in [
      "sudo: a password is required",
      "sudo: sorry, user x is not allowed to execute '/usr/bin/pmset' as root",
      "sudo: user x may not run sudo on host",
    ] {
      let runner = SudoPowerRunner(sudo: try fakeSudo(stderr: message, status: 1))
      do {
        try await runner.run(.setSleepDisabled(true))
        Issue.record("expected a throw")
      } catch ClosedLidPowerError.permissionUnavailable {
      } catch {
        Issue.record("expected permissionUnavailable for \(message), got \(error)")
      }
    }
  }

  @Test func otherNonZeroExitsStayCommandFailed() async throws {
    let cases: [(String, Int32)] = [
      ("pmset: something broke", 1), ("sudo: a password is required", 2), ("", 3),
    ]
    for (message, status) in cases {
      let runner = SudoPowerRunner(sudo: try fakeSudo(stderr: message, status: status))
      do {
        try await runner.run(.setSleepDisabled(false))
        Issue.record("expected a throw")
      } catch ClosedLidPowerError.commandFailed(let code) {
        #expect(code == status)
      } catch {
        Issue.record("expected commandFailed(\(status)), got \(error)")
      }
    }
  }

  @Test func aZeroSudoExitSucceeds() async throws {
    let runner = SudoPowerRunner(sudo: URL(fileURLWithPath: "/usr/bin/true"))
    try await runner.run(.setSleepDisabled(true))
  }

  @Test func boundedProcessCanRunWithAnEmptyEnvironment() async throws {
    let script = "test -z \"${HOME+x}\""
    let empty = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1,
      environment: [:])
    #expect(empty.status == 0)
    let inherited = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1)
    #expect(inherited.status != 0)
  }
}

private func fakeSudo(stderr: String, status: Int32) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("sudo-runner-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let script = directory.appendingPathComponent("sudo")
  let body = "#!/bin/sh\nprintf '%s\\n' '\(stderr)' >&2\nexit \(status)\n"
  try body.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return script
}
