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
    let runner = UserScriptPowerRunner(launcher: launcher, pid: 4242)
    try await runner.run(.setSleepDisabled(true))
    try await runner.run(.setSleepDisabled(false))
    #expect(launcher.arguments == [["on", "4242"], ["off"]])
  }

  @Test func theDefaultPidIsThisProcess() async throws {
    let launcher = FakeLauncher(finished("ok\n"))
    try await UserScriptPowerRunner(launcher: launcher).run(.setSleepDisabled(true))
    #expect(launcher.arguments == [["on", String(getpid())]])
  }

  @Test func revertedMapsToRevertedWhileUnresponsive() async {
    for run in [finished("reverted\n", status: 4), finished("reverted\n")] {
      do {
        try await UserScriptPowerRunner(launcher: FakeLauncher(run)).run(.setSleepDisabled(true))
        Issue.record("expected a throw for \(run)")
      } catch ClosedLidSessionError.revertedWhileUnresponsive {
      } catch {
        Issue.record("expected revertedWhileUnresponsive for \(run), got \(error)")
      }
    }
  }

  @Test func theScriptBeatRunsTheBeatVerb() async throws {
    let launcher = FakeLauncher(finished("ok\n"))
    ClosedLidScriptBeat(launcher: launcher).send()
    for _ in 0..<100 where launcher.arguments.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(launcher.arguments == [["beat"]])
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
    let arguments11 = String(repeating: "1", count: 11)
    for arguments in [
      [], ["bogus"], ["on"], ["on", "extra"], ["on", "1", "2"], ["on", ""], ["on", "-5"],
      ["on", "12a"], ["on", "0"], ["on", arguments11], ["off", "1"], ["beat", "1"],
      ["check", "1"], ["repair", "1"], ["probe", "1"], [""], ["ON"],
    ] {
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

/// Drives the real script against a temp HOME. The script honors `DILATED_POWER_TEST_SUDO` and
/// `DILATED_POWER_TEST_WAKE` only when it runs from inside a repo checkout, so these tests point
/// sudo at a recording fake and real sudo is never reached.
struct MASChannelRepairScriptTests {
  private static let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let script = repo.appendingPathComponent("packaging/mas/dilated-power")

  private final class Sandbox {
    let home: URL
    let sudoLog: URL
    let fakeSudo: URL
    var children: [Process] = []

    init() throws {
      let manager = FileManager.default
      home = manager.temporaryDirectory.appendingPathComponent("dilated-power-\(UUID().uuidString)")
      try manager.createDirectory(at: home, withIntermediateDirectories: true)
      sudoLog = home.appendingPathComponent("sudo.log")
      fakeSudo = home.appendingPathComponent("fake-sudo")
      try """
      #!/bin/bash
      echo "$@" >> "\(sudoLog.path)"
      exit 0
      """.write(to: fakeSudo, atomically: true, encoding: .utf8)
      try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSudo.path)
    }

    deinit {
      for child in children where child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: home)
    }

    var sessionDirectory: URL {
      home.appendingPathComponent("Library/Application Support/dilated-power")
    }
    var sessionFile: URL { sessionDirectory.appendingPathComponent("session") }
    var sudoCalls: [String] {
      ((try? String(contentsOf: sudoLog, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
    }

    func spawnSleeper() throws -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sleep")
      process.arguments = ["600"]
      try process.run()
      children.append(process)
      return process
    }

    func kill(_ process: Process) {
      process.terminate()
      process.waitUntilExit()
    }

    func run(
      script: URL = MASChannelRepairScriptTests.script, _ arguments: [String],
      wake: Int? = nil, useFakeSudo: Bool = true
    ) throws -> (status: Int32, out: String, err: String) {
      var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
      if useFakeSudo { environment["DILATED_POWER_TEST_SUDO"] = fakeSudo.path }
      if let wake { environment["DILATED_POWER_TEST_WAKE"] = String(wake) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [script.path] + arguments
      process.environment = environment
      let out = Pipe()
      let err = Pipe()
      process.standardOutput = out
      process.standardError = err
      try process.run()
      let outData = out.fileHandleForReading.readDataToEndOfFile()
      let errData = err.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (
        process.terminationStatus,
        String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
        String(decoding: errData, as: UTF8.self)
      )
    }

    func age(_ seconds: TimeInterval) throws {
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: sessionFile.path)
    }
  }

  private static func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }

  private static var now: Int { Int(Date().timeIntervalSince1970) }

  @Test func checkWithNoSessionIsNoneAndChangesNothing() throws {
    let box = try Sandbox()
    let result = try box.run(["check"])
    #expect(result.status == 0)
    #expect(result.out == "none")
    #expect(!FileManager.default.fileExists(atPath: box.sessionDirectory.path))
    #expect(box.sudoCalls.isEmpty)
  }

  @Test func onWritesAPrivateSessionAndEnablesSleep() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    let result = try box.run(["on", String(child.processIdentifier)])
    #expect(result.out == "ok")
    #expect(result.status == 0)
    #expect(box.sudoCalls == ["/usr/bin/pmset -a disablesleep 1"])
    #expect(try Self.permissions(box.sessionDirectory) == 0o700)
    #expect(try Self.permissions(box.sessionFile) == 0o600)
    let record = try String(contentsOf: box.sessionFile, encoding: .utf8)
    #expect(record.hasPrefix("\(child.processIdentifier) "))
    #expect(try box.run(["check"]).out == "live")
  }

  @Test func onForAMissingPidFailsWithoutEnabling() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    let pid = child.processIdentifier
    box.kill(child)
    let result = try box.run(["on", String(pid)])
    #expect(result.out == "failed")
    #expect(result.status == 1)
    #expect(box.sudoCalls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: box.sessionFile.path))
  }

  @Test func beatTouchesTheSessionAndIsNoneWithout() throws {
    let box = try Sandbox()
    #expect(try box.run(["beat"]).out == "none")
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    try box.age(300)
    #expect(try box.run(["beat"]).out == "ok")
    let modified =
      try FileManager.default.attributesOfItem(atPath: box.sessionFile.path)[
        .modificationDate] as? Date
    #expect(Date().timeIntervalSince(try #require(modified)) < 30)
  }

  @Test func checkReadsDeadWhenThePidIsGone() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    box.kill(child)
    let calls = box.sudoCalls
    #expect(try box.run(["check"]).out == "dead")
    #expect(box.sudoCalls == calls)
    #expect(FileManager.default.fileExists(atPath: box.sessionFile.path))
  }

  @Test func checkReadsDeadWhenThePidIsReusedWithAnotherStartTime() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    try FileManager.default.createDirectory(
      at: box.sessionDirectory, withIntermediateDirectories: true)
    try "\(child.processIdentifier) Thu Jan  1 00:00:00 1970\n".write(
      to: box.sessionFile, atomically: true, encoding: .utf8)
    #expect(try box.run(["check"]).out == "dead")
  }

  @Test func checkReadsStaleOnlyWhenTheHeartbeatAndTheWakeAreBothOld() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    try box.age(300)
    #expect(try box.run(["check"], wake: Self.now - 600).out == "stale")
    // The Mac just woke: an old heartbeat is the sleep, not a hung app.
    #expect(try box.run(["check"], wake: Self.now - 10).out == "live")
    try box.age(30)
    #expect(try box.run(["check"], wake: Self.now - 600).out == "live")
  }

  @Test func repairLeavesALiveSessionAlone() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    let result = try box.run(["repair"], wake: Self.now - 600)
    #expect(result.status == 0)
    #expect(result.out.isEmpty)
    #expect(box.sudoCalls == ["/usr/bin/pmset -a disablesleep 1"])
    #expect(FileManager.default.fileExists(atPath: box.sessionFile.path))
  }

  @Test func repairWithNoSessionExitsQuietlyWithoutSudo() throws {
    let box = try Sandbox()
    let result = try box.run(["repair"])
    #expect(result.status == 0)
    #expect(result.out.isEmpty)
    #expect(box.sudoCalls.isEmpty)
  }

  @Test func repairRevertsADeadSessionAndLeavesATombstone() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    let pid = child.processIdentifier
    _ = try box.run(["on", String(pid)])
    box.kill(child)
    let result = try box.run(["repair"])
    #expect(result.status == 0)
    #expect(
      box.sudoCalls == ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0"])
    #expect(!FileManager.default.fileExists(atPath: box.sessionFile.path))
    #expect(try box.run(["check"]).out == "reverted")
    // A second tick has nothing to do.
    #expect(try box.run(["repair"]).out.isEmpty)
    #expect(box.sudoCalls.count == 2)
    // The same pid asking again hears it was reverted, once, and sleep stays enabled.
    let again = try box.run(["on", String(pid)])
    #expect(again.out == "reverted")
    #expect(again.status == 4)
    #expect(box.sudoCalls.count == 2)
    #expect(try box.run(["check"]).out == "none")
  }

  @Test func repairRevertsAStaleSession() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    try box.age(300)
    _ = try box.run(["repair"], wake: Self.now - 600)
    #expect(box.sudoCalls.last == "/usr/bin/pmset -a disablesleep 0")
    #expect(try box.run(["check"]).out == "reverted")
  }

  @Test func aFailedRevertKeepsTheSessionForTheNextTick() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    box.kill(child)
    try """
    #!/bin/bash
    echo "sudo: a password is required"
    exit 1
    """.write(to: box.fakeSudo, atomically: true, encoding: .utf8)
    let result = try box.run(["repair"])
    #expect(result.out == "norule")
    #expect(FileManager.default.fileExists(atPath: box.sessionFile.path))
  }

  @Test func offRevertsAndClearsTheSession() throws {
    let box = try Sandbox()
    let child = try box.spawnSleeper()
    _ = try box.run(["on", String(child.processIdentifier)])
    #expect(try box.run(["off"]).out == "ok")
    #expect(box.sudoCalls.last == "/usr/bin/pmset -a disablesleep 0")
    #expect(try box.run(["check"]).out == "none")
  }

  @Test func theTestHooksAreIgnoredByACopyOutsideTheRepo() throws {
    let box = try Sandbox()
    let installed = box.home.appendingPathComponent("Application Scripts/dilated-power")
    try FileManager.default.createDirectory(
      at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Self.script, to: installed)
    let child = try box.spawnSleeper()
    // Put the session there by hand, so no verb that reaches sudo has to run.
    try FileManager.default.createDirectory(
      at: box.sessionDirectory, withIntermediateDirectories: true)
    let start = try box.run(["check"]).out
    #expect(start == "none")
    let line = Process()
    line.executableURL = URL(fileURLWithPath: "/bin/ps")
    line.arguments = ["-o", "lstart=", "-p", String(child.processIdentifier)]
    let pipe = Pipe()
    line.standardOutput = pipe
    try line.run()
    let lstart = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    line.waitUntilExit()
    try "\(child.processIdentifier) \(lstart)\n".write(
      to: box.sessionFile, atomically: true, encoding: .utf8)
    try box.age(300)
    // Only the real wake time can answer here. When the Mac woke under two minutes ago, skip.
    var raw = [UInt8](repeating: 0, count: 64)
    var size = raw.count
    guard sysctlbyname("kern.waketime", &raw, &size, nil, 0) == 0, size >= 8 else { return }
    let seconds = raw.withUnsafeBytes { $0.load(as: Int.self) }
    guard Self.now - seconds > 150 else { return }
    // The hook says the Mac woke ten seconds ago. A repo copy would believe it and say `live`.
    let result = try box.run(script: installed, ["check"], wake: Self.now - 10)
    #expect(result.out == "stale")
    #expect(box.sudoCalls.isEmpty)
  }
}
