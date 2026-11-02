import Foundation
import Testing

@testable import DilatedCore

struct ClosedLidPermissionTests {
  private static let good = ClosedLidFileInfo(
    isRegularFile: true, owner: 0, group: 0, mode: 0o444)

  private func permission(
    info: ClosedLidFileInfo? = good, content: Data? = ClosedLidPermission.ruleContent,
    probe: Bool = true, admin: Bool = true,
    runner: any PrivilegedScriptRunning = RecordingRunner(outcome: .succeeded)
  ) -> ClosedLidPermission {
    ClosedLidPermission(
      seams: .init(
        stat: { _ in info }, readFile: { _ in content }, probe: { probe }, isAdmin: { admin }),
      runner: runner)
  }

  @Test func theRuleContentIsFixed() {
    #expect(
      String(decoding: ClosedLidPermission.ruleContent, as: UTF8.self)
        == """
        Cmnd_Alias DILATED_PMSET = /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
        %admin ALL=(root) NOPASSWD: DILATED_PMSET

        """)
    #expect(ClosedLidPermission.rulePath == "/private/etc/sudoers.d/dilated")
  }

  @Test func detectsEveryState() async {
    #expect(await permission(info: nil, probe: false).state() == .notInstalled)
    #expect(await permission(info: nil).state() == .allowedByOtherRule)
    #expect(ClosedLidPermissionState.allowedByOtherRule.isUsable)
    #expect(ClosedLidPermissionState.ready.isUsable)
    #expect(!ClosedLidPermissionState.notInstalled.isUsable)
    #expect(!ClosedLidPermissionState.blocked.isUsable)
    #expect(await permission(content: Data("x\n".utf8)).state() == .needsRepair)
    #expect(await permission(content: nil).state() == .needsRepair)
    var info = Self.good
    info.owner = 501
    #expect(await permission(info: info).state() == .needsRepair)
    info = Self.good
    info.group = 20
    #expect(await permission(info: info).state() == .needsRepair)
    info = Self.good
    info.mode = 0o644
    #expect(await permission(info: info).state() == .needsRepair)
    info = Self.good
    info.isRegularFile = false
    #expect(await permission(info: info).state() == .needsRepair)
    #expect(await permission(probe: false).state() == .blocked)
    #expect(await permission().state() == .ready)
    #expect(await permission(admin: false).state() == .notAdmin)
    #expect(await permission(info: nil, admin: false).state() == .notAdmin)
    #expect(ClosedLidPermissionState.allowedByOtherRule.word == "allowedByOtherRule")
  }

  @Test func installAndRemoveScriptsAreConstantAndCheckSudoers() {
    let install = ClosedLidPermission.installScript
    #expect(install.contains("/usr/bin/mktemp /private/var/root/"))
    #expect(install.contains("/usr/bin/printf"))
    #expect(install.contains("/usr/sbin/visudo -cf \"$tmp\""))
    #expect(install.contains("/usr/bin/install -o root -g wheel -m 0444"))
    #expect(install.contains("/bin/mv -f \"$stage\" /private/etc/sudoers.d/dilated"))
    #expect(
      install.contains(
        "/usr/sbin/visudo -c || { /bin/rm -f /private/etc/sudoers.d/dilated; exit 1; }"))
    #expect(install.contains("DILATED_PMSET"))
    let remove = ClosedLidPermission.removeScript
    #expect(remove.contains("/bin/rm -f /private/etc/sudoers.d/dilated"))
    #expect(remove.hasSuffix("/usr/sbin/visudo -c"))
    let source = ClosedLidPermission.appleScriptSource(for: remove)
    #expect(source.hasPrefix("do shell script \""))
    #expect(source.hasSuffix("\" with administrator privileges"))
    let quoted = ClosedLidPermission.appleScriptSource(for: install)
    #expect(quoted.contains("\\\"$tmp\\\""))
    #expect(quoted.contains("\\\\n"))
  }

  @Test func installRunsTheFixedScriptThenRedetects() async {
    let runner = RecordingRunner(outcome: .succeeded)
    let outcome = await permission(runner: runner).install()
    #expect(outcome == .completed(.ready))
    #expect(
      await runner.scripts
        == [ClosedLidPermission.appleScriptSource(for: ClosedLidPermission.installScript)])
  }

  @Test func installReportsTheResultingStateEvenWhenItIsStillBlocked() async {
    let outcome = await permission(probe: false).install()
    #expect(outcome == .completed(.blocked))
  }

  @Test func removeRunsTheFixedScriptThenRedetects() async {
    let runner = RecordingRunner(outcome: .succeeded)
    let outcome = await permission(info: nil, probe: false, runner: runner).remove()
    #expect(outcome == .completed(.notInstalled))
    #expect(
      await runner.scripts
        == [ClosedLidPermission.appleScriptSource(for: ClosedLidPermission.removeScript)])
  }

  @Test func cancellingTheAdminPromptIsNotAnError() async {
    let runner = RecordingRunner(outcome: .cancelled)
    #expect(await permission(runner: runner).install() == .cancelled)
    #expect(await permission(runner: runner).remove() == .cancelled)
    #expect(
      ClosedLidPermission.outcome(
        status: 1, stderr: "execution error: User canceled. (-128)") == .cancelled)
    #expect(ClosedLidPermission.outcome(status: 1, stderr: "boom\n") == .failed("boom"))
    #expect(
      ClosedLidPermission.outcome(status: 1, stderr: "")
        == .failed("The administrator command failed."))
    #expect(ClosedLidPermission.outcome(status: 0, stderr: "") == .succeeded)
    #expect(
      ClosedLidPermission.outcome(status: 15, stderr: "", timedOut: true)
        == .failed("The administrator prompt timed out."))
  }

  @Test func theProbeChecksBothPmsetCommands() {
    #expect(
      ClosedLidPermission.probeArgumentSets == [
        ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"],
        ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
      ])
  }

  @Test func theOsascriptRunnerMapsExitStatusAndStderr() async {
    let sh = URL(fileURLWithPath: "/bin/sh")
    func run(_ command: String, timeout: TimeInterval = 10) async -> PrivilegedScriptOutcome {
      await OsascriptAdminRunner.execute(
        executable: sh, arguments: ["-c", command], timeout: timeout)
    }
    #expect(await run("exit 0") == .succeeded)
    #expect(await run("echo 'execution error: User canceled. (-128)' >&2; exit 1") == .cancelled)
    #expect(await run("echo 'nope' >&2; exit 1") == .failed("nope"))
    #expect(
      await OsascriptAdminRunner.execute(
        executable: URL(fileURLWithPath: "/nonexistent/osascript"), arguments: [], timeout: 5)
        == .failed("The administrator command couldn't start."))
    #expect(await run("sleep 30", timeout: 0.3) == .failed("The administrator prompt timed out."))
  }

  @Test func theAdminPromptBoundIsFiveMinutes() {
    // Separate from BoundedProcess, which caps at 3 seconds and would kill the prompt.
    #expect(OsascriptAdminRunner.promptTimeout == 300)
  }

  @Test func aFailedScriptReportsTheStateAfterward() async {
    let runner = RecordingRunner(outcome: .failed("visudo said no"))
    let outcome = await permission(info: nil, probe: false, runner: runner).install()
    #expect(outcome == .failed("visudo said no", .notInstalled))
  }

  @Test func installRefusesWithoutPromptingForNonAdmins() async {
    let runner = RecordingRunner(outcome: .succeeded)
    let outcome = await permission(admin: false, runner: runner).install()
    guard case .failed(_, .notAdmin) = outcome else {
      Issue.record("expected a notAdmin failure, got \(outcome)")
      return
    }
    #expect(await runner.scripts.isEmpty)
  }

  @Test func restoreNormalSleepRunsTheFixedPmsetCommand() async {
    let runner = RecordingRunner(outcome: .succeeded)
    #expect(await permission(runner: runner).restoreNormalSleep() == .succeeded)
    let scripts = await runner.scripts
    #expect(scripts.count == 1)
    #expect(scripts[0].contains("/usr/bin/pmset -a disablesleep 0"))
    #expect(scripts[0].hasSuffix("with administrator privileges"))
    let cancelled = RecordingRunner(outcome: .cancelled)
    #expect(await permission(runner: cancelled).restoreNormalSleep() == .cancelled)
  }

  @Test func visudoAcceptsTheFixedContent() throws {
    let visudo = "/usr/sbin/visudo"
    guard FileManager.default.isExecutableFile(atPath: visudo) else { return }
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("dilated-sudoers-\(UUID().uuidString)")
    try ClosedLidPermission.ruleContent.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: file.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: visudo)
    process.arguments = ["-cf", file.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "\(text)")
  }
}

private actor RecordingRunner: PrivilegedScriptRunning {
  private(set) var scripts: [String] = []
  private let outcome: PrivilegedScriptOutcome
  init(outcome: PrivilegedScriptOutcome) { self.outcome = outcome }
  func run(script: String) -> PrivilegedScriptOutcome {
    scripts.append(script)
    return outcome
  }
}
