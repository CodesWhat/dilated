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
    #expect(await permission(info: nil).state() == .notInstalled)
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
    let outcome = await permission(info: nil, runner: runner).remove()
    #expect(outcome == .completed(.notInstalled))
    #expect(
      await runner.scripts
        == [ClosedLidPermission.appleScriptSource(for: ClosedLidPermission.removeScript)])
  }

  @Test func cancellingTheAdminPromptIsNotAnError() async {
    let runner = RecordingRunner(outcome: .cancelled)
    #expect(await permission(runner: runner).install() == .cancelled)
    #expect(await permission(runner: runner).remove() == .cancelled)
    #expect(ClosedLidPermission.outcome(errorNumber: -128, message: "User canceled.") == .cancelled)
    #expect(ClosedLidPermission.outcome(errorNumber: 1, message: "boom") == .failed("boom"))
    #expect(
      ClosedLidPermission.outcome(errorNumber: nil, message: nil)
        == .failed("The administrator command failed."))
  }

  @Test func aFailedScriptReportsTheStateAfterward() async {
    let runner = RecordingRunner(outcome: .failed("visudo said no"))
    let outcome = await permission(info: nil, runner: runner).install()
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
