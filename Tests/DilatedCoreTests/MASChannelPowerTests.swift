import Foundation
import Testing

@testable import DilatedCore

private final class FakeLauncher: UserScriptLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let result: UserScriptRun
  private var calls: [[String]] = []

  init(_ result: UserScriptRun) { self.result = result }

  var arguments: [[String]] { lock.withLock { calls } }

  func run(arguments: [String]) async -> UserScriptRun {
    lock.withLock { calls.append(arguments) }
    return result
  }
}

private func finished(_ output: String, status: Int32? = nil) -> UserScriptRun {
  .finished(output: output, failureStatus: status)
}

struct MASChannelUserScriptRunnerTests {
  @Test func onAndOffRunTheMatchingVerb() async throws {
    let launcher = FakeLauncher(finished("ok\n"))
    let runner = UserScriptPowerRunner(launcher: launcher)
    try await runner.run(.setSleepDisabled(true))
    try await runner.run(.setSleepDisabled(false))
    #expect(launcher.arguments == [["on"], ["off"]])
  }

  @Test func okIsSuccess() async throws {
    try await UserScriptPowerRunner(launcher: FakeLauncher(finished("ok")))
      .run(.setSleepDisabled(true))
  }

  @Test func norulePermissionAndMissingScriptAreUnavailable() async {
    for run in [finished("norule\n", status: 3), finished("norule\n"), .missing] {
      do {
        try await UserScriptPowerRunner(launcher: FakeLauncher(run)).run(.setSleepDisabled(true))
        Issue.record("expected a throw for \(run)")
      } catch ClosedLidPowerError.permissionUnavailable {
      } catch {
        Issue.record("expected permissionUnavailable for \(run), got \(error)")
      }
    }
  }

  @Test func timeoutIsCommandTimedOut() async {
    do {
      try await UserScriptPowerRunner(launcher: FakeLauncher(.timedOut))
        .run(.setSleepDisabled(false))
      Issue.record("expected a throw")
    } catch ClosedLidPowerError.commandTimedOut {
    } catch {
      Issue.record("expected commandTimedOut, got \(error)")
    }
  }

  @Test func failureKeepsItsStatusAndDefaultsToOne() async {
    let cases: [(UserScriptRun, Int32)] = [
      (finished("failed\n", status: 5), 5), (finished("failed\n", status: 1), 1),
      (finished("garbage", status: nil), 1), (finished("", status: 2), 2),
      (finished("ok", status: 4), 4),
    ]
    for (run, expected) in cases {
      do {
        try await UserScriptPowerRunner(launcher: FakeLauncher(run)).run(.setSleepDisabled(true))
        Issue.record("expected a throw for \(run)")
      } catch ClosedLidPowerError.commandFailed(let status) {
        #expect(status == expected)
      } catch {
        Issue.record("expected commandFailed for \(run), got \(error)")
      }
    }
  }

  @Test func theFirstWordDecidesNotLaterOutput() async throws {
    try await UserScriptPowerRunner(launcher: FakeLauncher(finished("\n  ok extra words")))
      .run(.setSleepDisabled(true))
  }
}

struct MASChannelScriptStateTests {
  @Test func probeMapsEachOutcomeToAState() async {
    let cases: [(UserScriptRun, ClosedLidScriptState)] = [
      (.missing, .scriptMissing),
      (finished("ok\n"), .ready),
      (finished("norule\n", status: 3), .ruleMissing),
      (finished("failed\n", status: 1), .ruleMissing),
      (finished("ok\n", status: 1), .ruleMissing),
      (finished("", status: nil), .ruleMissing),
      (.timedOut, .ruleMissing),
    ]
    for (run, expected) in cases {
      let launcher = FakeLauncher(run)
      let state = await ClosedLidScriptPermission(launcher: launcher).state()
      #expect(state == expected, "\(run)")
      #expect(launcher.arguments == [["probe"]])
    }
  }
}

struct MASChannelScriptContractTests {
  private static let script = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("packaging/mas/dilated-power")

  private func run(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path] + arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  @Test func badArgumentsPrintUsageAndExit64WithoutTouchingSudo() throws {
    for arguments in [[], ["bogus"], ["on", "extra"], [""], ["ON"]] {
      let result = try run(arguments)
      #expect(result.status == 64, "\(arguments)")
      #expect(result.out.isEmpty, "\(arguments)")
      #expect(result.err.hasPrefix("usage"), "\(arguments)")
    }
  }

  @Test func theScriptIsExecutableInTheRepo() throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: Self.script.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    #expect(mode & 0o111 != 0)
  }
}
