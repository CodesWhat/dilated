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

  @Test func aNonZeroSudoExitIsPermissionUnavailableNotAGenericFailure() async {
    let runner = SudoPowerRunner(sudo: URL(fileURLWithPath: "/usr/bin/false"))
    for disabled in [true, false] {
      do {
        try await runner.run(.setSleepDisabled(disabled))
        Issue.record("expected a throw")
      } catch ClosedLidPowerError.permissionUnavailable {
      } catch {
        Issue.record("expected permissionUnavailable, got \(error)")
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
