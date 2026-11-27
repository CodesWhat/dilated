import CryptoKit
import DilatedCore
import Foundation
import Testing

@testable import DilatedSetupCore

/// Records every side effect in order, so a test can assert the sequence.
final class SetupLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ item: String) { lock.withLock { items.append(item) } }
  var events: [String] { lock.withLock { items } }
}

final class FakeSetupFiles: SetupFileSystem, @unchecked Sendable {
  struct Entry: Equatable {
    var data: Data
    var mode: UInt16
  }

  private let lock = NSLock()
  private var files: [String: Entry] = [:]
  private var directories: Set<String> = []
  /// Paths whose atomic write throws.
  var failingWrites: Set<String> = []
  let log: SetupLog

  init(log: SetupLog) { self.log = log }

  func put(_ path: String, _ data: Data, mode: UInt16 = 0o644) {
    lock.withLock { files[path] = Entry(data: data, mode: mode) }
  }

  func entry(_ path: String) -> Entry? { lock.withLock { files[path] } }

  func read(_ path: String) -> Data? { lock.withLock { files[path]?.data } }

  func exists(_ path: String) -> Bool {
    lock.withLock { files[path] != nil || directories.contains(path) }
  }

  func writeAtomically(_ data: Data, to path: String, mode: UInt16, directoryMode: UInt16) throws {
    log.add("write \(path)")
    if failingWrites.contains(path) { throw ClosedLidSetupLiveError(message: "disk full") }
    lock.withLock {
      directories.insert((path as NSString).deletingLastPathComponent)
      files[path] = Entry(data: data, mode: mode)
    }
  }

  func remove(_ path: String) throws {
    log.add("remove \(path)")
    _ = lock.withLock { files.removeValue(forKey: path) }
  }

  func removeDirectoryIfEmpty(_ path: String) {
    let empty = lock.withLock { !files.keys.contains { $0.hasPrefix(path + "/") } }
    if empty {
      log.add("rmdir \(path)")
      _ = lock.withLock { directories.remove(path) }
    }
  }
}

final class FakeLaunchd: LaunchAgentControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var isUp = false
  let log: SetupLog
  var bootstrapFails = false
  /// A bootstrap that returns cleanly but leaves the job unloaded.
  var neverLoads = false

  init(log: SetupLog) { self.log = log }

  func bootstrap(domain: String, plistPath: String) async throws {
    log.add("bootstrap \(domain)")
    if bootstrapFails { throw ClosedLidSetupLiveError(message: "boom") }
    if !neverLoads { lock.withLock { isUp = true } }
  }
  func bootout(target: String) async {
    log.add("bootout \(target)")
    lock.withLock { isUp = false }
  }
  func isLoaded(target: String) async -> Bool { lock.withLock { isUp } }
}

struct FakePower: PowerScriptRunning {
  let log: SetupLog
  var fails = false
  var sleepRestored = true
  /// What the script reports: whether a session or tombstone was ours.
  var owned = true
  func beginRemoval(scriptPath: String) async throws -> Bool {
    log.add("begin removal")
    if fails { throw ClosedLidSetupLiveError(message: "nope") }
    return owned
  }
  func finishRemoval(scriptPath: String) async throws {
    log.add("finish removal")
  }
  func confirmsNormalSleep() async -> Bool {
    log.add("readback")
    return sleepRestored
  }
}

final class FakeRule: ClosedLidRuleControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var current: ClosedLidPermissionState
  private let afterInstall: ClosedLidPermissionOutcome
  private let afterRemove: ClosedLidPermissionOutcome
  let log: SetupLog

  init(
    state: ClosedLidPermissionState, log: SetupLog,
    afterInstall: ClosedLidPermissionOutcome = .completed(.ready),
    afterRemove: ClosedLidPermissionOutcome = .completed(.notInstalled)
  ) {
    current = state
    self.log = log
    self.afterInstall = afterInstall
    self.afterRemove = afterRemove
  }

  func state() async -> ClosedLidPermissionState { lock.withLock { current } }

  func install() async -> ClosedLidPermissionOutcome {
    log.add("rule install")
    if case .completed(let state) = afterInstall { lock.withLock { current = state } }
    return afterInstall
  }

  func remove() async -> ClosedLidPermissionOutcome {
    log.add("rule remove")
    return afterRemove
  }
}

private let scriptBytes = Data("#!/bin/bash\necho ok\n".utf8)
private let templateText = "<string>__HOME__/Library/Application Scripts/x/dilated-power</string>"

private func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Rig {
  let log = SetupLog()
  let files: FakeSetupFiles
  let paths = ClosedLidSetupPaths(home: "/Users/test", uid: 501)
  let setup: ClosedLidSetup
  let rule: FakeRule

  init(
    rule ruleState: ClosedLidPermissionState = .notInstalled,
    afterInstall: ClosedLidPermissionOutcome = .completed(.ready),
    afterRemove: ClosedLidPermissionOutcome = .completed(.notInstalled),
    powerFails: Bool = false, sleepRestored: Bool = true, ownsSleep: Bool = true,
    bootstrapFails: Bool = false,
    neverLoads: Bool = false,
    assets: ClosedLidSetupAssets? = nil
  ) {
    let log = log
    files = FakeSetupFiles(log: log)
    rule = FakeRule(
      state: ruleState, log: log, afterInstall: afterInstall, afterRemove: afterRemove)
    let launchd = FakeLaunchd(log: log)
    launchd.bootstrapFails = bootstrapFails
    launchd.neverLoads = neverLoads
    setup = ClosedLidSetup(
      paths: paths,
      assets: assets
        ?? ClosedLidSetupAssets(
          script: scriptBytes, plistTemplate: templateText,
          expectedScriptSHA256: digest(scriptBytes)),
      files: files, launchd: launchd,
      power: FakePower(
        log: log, fails: powerFails, sleepRestored: sleepRestored, owned: ownsSleep), rule: rule)
  }
}

struct ClosedLidSetupInstallTests {
  @Test func installsRuleThenScriptThenAgentInThatOrder() async {
    let rig = Rig()
    #expect(await rig.setup.install() == .completed)
    let p = rig.paths
    #expect(
      rig.log.events == [
        "rule install",
        "write \(p.stateFile)",
        "write \(p.scriptPath)",
        "write \(p.agentPlistPath)",
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
        "bootstrap gui/501",
        "remove \(p.removalMarker)",
      ])
  }

  @Test func writesTheScriptExecutableAndTheAgentWithTheRealHome() async throws {
    let rig = Rig(rule: .ready)
    #expect(await rig.setup.install() == .completed)
    #expect(rig.files.entry(rig.paths.scriptPath) == .init(data: scriptBytes, mode: 0o755))
    let plist = try #require(rig.files.entry(rig.paths.agentPlistPath))
    let text = String(decoding: plist.data, as: UTF8.self)
    #expect(text.contains("/Users/test/Library/Application Scripts/x/dilated-power"))
    #expect(!text.contains("__HOME__"))
    #expect(rig.files.entry(rig.paths.stateFile) == nil)
  }

  @Test func skipsTheRuleWithoutAPromptWhenItAlreadyWorks() async {
    for state in [ClosedLidPermissionState.ready, .allowedByOtherRule] {
      let rig = Rig(rule: state)
      #expect(await rig.setup.install() == .completed)
      #expect(!rig.log.events.contains("rule install"))
      #expect(rig.files.entry(rig.paths.stateFile) == nil)
    }
  }

  @Test func skippingTheRuleNeverReachesTheAdminRunner() async {
    final class CountingRunner: PrivilegedScriptRunning, @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      var runs: Int { lock.withLock { count } }
      func run(script: String) async -> PrivilegedScriptOutcome {
        lock.withLock { count += 1 }
        return .succeeded
      }
    }
    let runner = CountingRunner()
    // Another app's rule: no file at our path, but sudo allows both commands.
    let permission = ClosedLidPermission(
      seams: .init(stat: { _ in nil }, readFile: { _ in nil }, probe: { true }, isAdmin: { true }),
      runner: runner)
    let log = SetupLog()
    let setup = ClosedLidSetup(
      paths: .init(home: "/Users/test", uid: 501),
      assets: .init(
        script: scriptBytes, plistTemplate: templateText, expectedScriptSHA256: digest(scriptBytes)),
      files: FakeSetupFiles(log: log), launchd: FakeLaunchd(log: log), power: FakePower(log: log),
      rule: permission)
    #expect(await setup.install() == .completed)
    #expect(runner.runs == 0)
  }

  @Test func recordsThatItCreatedTheRuleOnlyWhenTheFileWasAbsent() async throws {
    let fresh = Rig(rule: .notInstalled)
    _ = await fresh.setup.install()
    let record = try #require(fresh.files.entry(fresh.paths.stateFile))
    #expect(record.mode == 0o600)
    #expect(String(decoding: record.data, as: UTF8.self).contains("true"))

    let repaired = Rig(rule: .needsRepair)
    _ = await repaired.setup.install()
    #expect(repaired.log.events.contains("rule install"))
    #expect(repaired.files.entry(repaired.paths.stateFile) == nil)
  }

  @Test func reinstallIsIdempotent() async {
    let rig = Rig(rule: .notInstalled)
    #expect(await rig.setup.install() == .completed)
    let first = rig.files.entry(rig.paths.scriptPath)
    rig.log.add("--second--")
    #expect(await rig.setup.install() == .completed)
    let second = rig.log.events.drop { $0 != "--second--" }
    #expect(
      Array(second) == [
        "--second--",
        "write \(rig.paths.scriptPath)",
        "write \(rig.paths.agentPlistPath)",
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
        "bootstrap gui/501",
        "remove \(rig.paths.removalMarker)",
      ])
    #expect(rig.files.entry(rig.paths.scriptPath) == first)
    // The second run found a working rule, so the record from the first run stays.
    #expect(rig.files.entry(rig.paths.stateFile) != nil)
  }

  @Test func overwritesAnOutdatedScript() async {
    let rig = Rig(rule: .ready)
    rig.files.put(rig.paths.scriptPath, Data("old".utf8), mode: 0o755)
    #expect(await rig.setup.status().script == .outdated)
    #expect(await rig.setup.install() == .completed)
    #expect(await rig.setup.status().script == .present)
  }

  @Test func aCancelledPromptStopsBeforeAnythingIsWritten() async {
    let rig = Rig(afterInstall: .cancelled)
    #expect(await rig.setup.install() == .cancelled)
    #expect(rig.log.events == ["rule install"])
  }

  @Test func aFailedRuleInstallStops() async {
    let rig = Rig(afterInstall: .failed("visudo said no", .notInstalled))
    #expect(await rig.setup.install() == .failed("visudo said no"))
    #expect(rig.log.events == ["rule install"])
  }

  @Test func aRuleThatStillBlocksPmsetFails() async {
    let rig = Rig(afterInstall: .completed(.blocked))
    guard case .failed = await rig.setup.install() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.files.entry(rig.paths.scriptPath) == nil)
  }

  @Test func aScriptThatFailsItsChecksumInstallsNothingAndShowsNoPrompt() async {
    let rig = Rig(
      assets: .init(
        script: Data("tampered".utf8), plistTemplate: templateText,
        expectedScriptSHA256: digest(scriptBytes)))
    guard case .failed = await rig.setup.install() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.log.events.isEmpty)
  }

  @Test func aBootstrapFailureIsReported() async {
    let rig = Rig(rule: .ready, bootstrapFails: true)
    #expect(
      await rig.setup.install() == .failed("Couldn't load the repair agent: boom"))
    #expect(await rig.setup.status().agent == .notLoaded)
  }

  @Test func aBootstrapThatLeavesTheAgentUnloadedIsNotSuccess() async {
    let rig = Rig(rule: .ready, neverLoads: true)
    guard case .failed(let message) = await rig.setup.install() else {
      Issue.record("expected a failure")
      return
    }
    #expect(message.contains("didn't load"))
    #expect(await rig.setup.status().agent == .notLoaded)
    #expect(!(await rig.setup.status().isInstalled))
  }

  @Test func installClearsTheRemovalMarkerOnlyAfterTheAgentIsLoaded() async {
    for (neverLoads, cleared) in [(false, true), (true, false)] {
      let rig = Rig(rule: .ready, neverLoads: neverLoads)
      rig.files.put(rig.paths.removalMarker, Data("removing\n".utf8))
      _ = await rig.setup.install()
      #expect((rig.files.entry(rig.paths.removalMarker) == nil) == cleared)
    }
    let failed = Rig(rule: .ready, bootstrapFails: true)
    failed.files.put(failed.paths.removalMarker, Data("removing\n".utf8))
    _ = await failed.setup.install()
    #expect(failed.files.entry(failed.paths.removalMarker) != nil)
  }

  @Test func aSuccessfulInstallLeavesTheAgentLoaded() async {
    let rig = Rig(rule: .ready)
    #expect(await rig.setup.install() == .completed)
    #expect(await rig.setup.status().agent == .loaded)
    #expect(await rig.setup.status().isInstalled)
  }
}

struct ClosedLidSetupRemoveTests {
  private func installed(_ rig: Rig, recordRule: Bool) {
    rig.files.put(rig.paths.scriptPath, scriptBytes, mode: 0o755)
    rig.files.put(rig.paths.agentPlistPath, Data("plist".utf8))
    if recordRule {
      rig.files.put(
        rig.paths.stateFile, Data(#"{"ruleInstalledByCompanion":true}"#.utf8), mode: 0o600)
    }
  }

  @Test func removesAgentThenScriptThenRuleThenRecord() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: true)
    #expect(await rig.setup.remove() == .completed)
    let p = rig.paths
    #expect(
      rig.log.events == [
        "begin removal",
        "readback",
        "finish removal",
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
        "remove \(p.agentPlistPath)",
        "remove \(p.scriptPath)",
        "rmdir \(p.scriptsDirectory)",
        "rule remove",
        "remove \(p.stateFile)",
        "rmdir \(p.stateDirectory)",
      ])
  }

  @Test func blocksEnablesAndRevertsBeforeAnythingElseWithOrWithoutASession() async {
    for hasSession in [true, false] {
      // Explicitly owned: the readback in events[1] only happens when begin-removal reports a
      // session of ours, which the no-session pass gets from this flag, not from a session file.
      let rig = Rig(rule: .ready, ownsSleep: true)
      installed(rig, recordRule: false)
      if hasSession { rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8)) }
      #expect(await rig.setup.remove() == .completed)
      #expect(rig.log.events.first == "begin removal")
      #expect(rig.log.events[1] == "readback")
      #expect(rig.log.events[2] == "finish removal")
      #expect(rig.log.events[3].hasPrefix("bootout"))
    }
  }

  @Test func stopsWhenTheSessionCannotBeReverted() async {
    let rig = Rig(rule: .ready, powerFails: true)
    installed(rig, recordRule: true)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.log.events == ["begin removal"])
    #expect(rig.files.entry(rig.paths.scriptPath) != nil)
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
  }

  @Test func keepsTheRecoveryAssetsUntilNormalSleepIsConfirmed() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: true)
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.log.events == ["begin removal", "readback"])
    #expect(rig.files.entry(rig.paths.scriptPath) != nil)
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
    #expect(rig.files.entry(rig.paths.stateFile) != nil)
  }

  @Test func aForeignDisableWithNoSessionLetsRemoveComplete() async {
    // Another app holds disablesleep: begin-removal answers none, so there's no readback to fail.
    let rig = Rig(rule: .ready, sleepRestored: false, ownsSleep: false)
    installed(rig, recordRule: false)
    #expect(await rig.setup.remove() == .completed)
    #expect(rig.log.events.contains("begin removal"))
    #expect(!rig.log.events.contains("readback"))
    #expect(rig.files.entry(rig.paths.scriptPath) == nil)
    #expect(rig.files.entry(rig.paths.agentPlistPath) == nil)
  }

  @Test func aMissingScriptWithAnOwnedSessionIsRestoredThenRemovedThroughTheStagedFlow() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    let before = rig.log.events.count
    #expect(await rig.setup.remove() == .completed)
    let p = rig.paths
    #expect(
      Array(rig.log.events.dropFirst(before)) == [
        "write \(p.scriptPath)",
        "begin removal",
        "readback",
        "finish removal",
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
        "remove \(p.agentPlistPath)",
        "remove \(p.scriptPath)",
        "rmdir \(p.scriptsDirectory)",
        "remove \(p.stateFile)",
        "rmdir \(p.stateDirectory)",
      ])
  }

  @Test func aRestoredScriptStaysWhenTheReadbackFails() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    let before = rig.log.events.count
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(
      Array(rig.log.events.dropFirst(before)) == [
        "write \(rig.paths.scriptPath)", "begin removal", "readback",
      ])
    #expect(rig.files.entry(rig.paths.scriptPath)?.data == scriptBytes)
    #expect(rig.files.entry(rig.paths.scriptPath)?.mode == 0o755)
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
    #expect(rig.files.entry(rig.paths.sessionFile) != nil)
  }

  @Test func aMissingScriptWithBadBundledBytesKeepsEverythingAndRunsNothing() async {
    let rig = Rig(
      rule: .ready,
      assets: ClosedLidSetupAssets(
        script: scriptBytes, plistTemplate: templateText, expectedScriptSHA256: "not-the-hash"))
    installed(rig, recordRule: true)
    try? rig.files.remove(rig.paths.scriptPath)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    let before = rig.log.events.count
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.log.events.count == before)
    #expect(rig.files.entry(rig.paths.scriptPath) == nil)
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
    #expect(rig.files.entry(rig.paths.sessionFile) != nil)
    #expect(rig.files.entry(rig.paths.stateFile) != nil)
  }

  @Test func aFailedScriptRestoreKeepsTheAgentAndNeverBeginsRemoval() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: true)
    try? rig.files.remove(rig.paths.scriptPath)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    rig.files.failingWrites = [rig.paths.scriptPath]
    let before = rig.log.events.count
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(Array(rig.log.events.dropFirst(before)) == ["write \(rig.paths.scriptPath)"])
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
    #expect(rig.files.entry(rig.paths.sessionFile) != nil)
    #expect(rig.files.entry(rig.paths.stateFile) != nil)
  }

  @Test func aMissingScriptWithOnlyTheRestoreLatchIsRestoredAndStillOwesTheReadback() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    rig.files.put(rig.paths.restorePendingFile, Data("pending".utf8))
    let before = rig.log.events.count
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(
      Array(rig.log.events.dropFirst(before)) == [
        "write \(rig.paths.scriptPath)", "begin removal", "readback",
      ])
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
  }

  @Test func aMissingScriptWithAForeignDisableAndNoSessionKeepsTheCurrentCleanup() async {
    let rig = Rig(rule: .ready, sleepRestored: false, ownsSleep: false)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    let before = rig.log.events.count
    #expect(await rig.setup.remove() == .completed)
    #expect(!rig.log.events.dropFirst(before).contains("write \(rig.paths.scriptPath)"))
    #expect(!rig.log.events.contains("begin removal"))
    #expect(!rig.log.events.contains("readback"))
    #expect(rig.files.entry(rig.paths.agentPlistPath) == nil)
  }

  @Test func aMissingScriptWithNoSessionRemovesTheAgentWithoutAReadback() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    #expect(await rig.setup.remove() == .completed)
    #expect(!rig.log.events.contains("readback"))
    #expect(rig.files.entry(rig.paths.agentPlistPath) == nil)
  }

  @Test func theMarkerSurvivesARemoveAndTheNextInstallClearsItAfterTheAgentLoads() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.removalMarker, Data("removing\n".utf8))
    #expect(await rig.setup.remove() == .completed)
    #expect(rig.files.entry(rig.paths.removalMarker) != nil)
    #expect(await rig.setup.install() == .completed)
    #expect(rig.files.entry(rig.paths.removalMarker) == nil)
    let blocked = Rig(rule: .ready, neverLoads: true)
    blocked.files.put(blocked.paths.removalMarker, Data("removing\n".utf8))
    _ = await blocked.setup.install()
    #expect(blocked.files.entry(blocked.paths.removalMarker) != nil)
  }

  @Test func aVerifiedReinstallClearsAStaleRestoreLatchAndOtherwiseKeepsIt() async {
    let clean = Rig(rule: .ready)
    clean.files.put(clean.paths.restorePendingFile, Data("pending\n".utf8))
    #expect(await clean.setup.install() == .completed)
    #expect(clean.files.entry(clean.paths.restorePendingFile) == nil)

    let dirty = Rig(rule: .ready, sleepRestored: false)
    dirty.files.put(dirty.paths.restorePendingFile, Data("pending\n".utf8))
    #expect(await dirty.setup.install() == .completed)
    #expect(dirty.files.entry(dirty.paths.restorePendingFile) != nil)

    let live = Rig(rule: .ready)
    live.files.put(live.paths.restorePendingFile, Data("pending\n".utf8))
    live.files.put(live.paths.sessionFile, Data("1 x\n".utf8))
    #expect(await live.setup.install() == .completed)
    #expect(live.files.entry(live.paths.restorePendingFile) != nil)
    #expect(!live.log.events.contains("readback"))

    let unloaded = Rig(rule: .ready, neverLoads: true)
    unloaded.files.put(unloaded.paths.restorePendingFile, Data("pending\n".utf8))
    _ = await unloaded.setup.install()
    #expect(unloaded.files.entry(unloaded.paths.restorePendingFile) != nil)
  }

  @Test func aRetryAfterAFailedReadbackStillOwnsTheSessionAndChecksAgain() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    for _ in 0..<2 {
      guard case .failed = await rig.setup.remove() else {
        Issue.record("expected a failure")
        return
      }
    }
    #expect(rig.log.events == ["begin removal", "readback", "begin removal", "readback"])
    #expect(rig.files.entry(rig.paths.sessionFile) != nil)
    #expect(rig.files.entry(rig.paths.agentPlistPath) != nil)
  }

  @Test func finishRemovalRunsOnlyAfterTheReadbackConfirmsNormalSleep() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    #expect(await rig.setup.remove() == .completed)
    #expect(
      Array(rig.log.events.prefix(4)) == [
        "begin removal", "readback", "finish removal",
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
      ])
  }

  @Test func aStaleTombstoneWithNoSessionIsNotOurs() async {
    // Another app holds disablesleep after an old repair left a tombstone: nothing to read back.
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    try? rig.files.remove(rig.paths.scriptPath)
    let tombstone = "/Users/test/Library/Application Support/dilated-power/tombstone"
    rig.files.put(tombstone, Data("reverted 7\n".utf8))
    #expect(await rig.setup.remove() == .completed)
    #expect(!rig.log.events.contains("readback"))
    #expect(rig.files.entry(tombstone) != nil)
  }

  @Test func aFailedRemoveKeepsTheRemovalMarker() async {
    let rig = Rig(rule: .ready, sleepRestored: false)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.removalMarker, Data("removing\n".utf8))
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.files.entry(rig.paths.removalMarker) != nil)
  }

  @Test func replacesAnOutdatedScriptBeforeBeginningRemoval() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.scriptPath, Data("old".utf8), mode: 0o755)
    #expect(await rig.setup.remove() == .completed)
    #expect(Array(rig.log.events.prefix(2)) == ["write \(rig.paths.scriptPath)", "begin removal"])
  }

  @Test func neverRemovesARuleItDidNotInstall() async {
    for state in [
      ClosedLidPermissionState.ready, .allowedByOtherRule,
    ] {
      let rig = Rig(rule: state)
      installed(rig, recordRule: false)
      #expect(await rig.setup.remove() == .completed)
      #expect(!rig.log.events.contains("rule remove"))
    }
  }

  @Test func aReinstallOverAnExistingRuleKeepsTheRuleItOriginallyCreated() async {
    let rig = Rig(rule: .notInstalled)
    #expect(await rig.setup.install() == .completed)
    #expect(await rig.setup.install() == .completed)
    #expect(await rig.setup.remove() == .completed)
    #expect(rig.log.events.contains("rule remove"))
  }

  @Test func aCancelledRuleRemovalKeepsTheRecordForNextTime() async {
    let rig = Rig(rule: .ready, afterRemove: .cancelled)
    installed(rig, recordRule: true)
    #expect(await rig.setup.remove() == .cancelled)
    #expect(rig.files.entry(rig.paths.stateFile) != nil)
    #expect(rig.files.entry(rig.paths.scriptPath) == nil)
  }

  @Test func removingWhenNothingIsInstalledIsFine() async {
    let rig = Rig(rule: .notInstalled)
    #expect(await rig.setup.remove() == .completed)
    #expect(!rig.log.events.contains("begin removal"))
  }
}

struct ClosedLidSetupStatusTests {
  @Test func reportsEachPiece() async {
    let rig = Rig(rule: .allowedByOtherRule)
    var status = await rig.setup.status()
    #expect(status.rule == .allowedByOtherRule)
    #expect(status.script == .missing)
    #expect(status.agent == .notLoaded)
    #expect(!status.isInstalled)

    rig.files.put(rig.paths.scriptPath, scriptBytes)
    status = await rig.setup.status()
    #expect(status.script == .present)
  }

  @Test func mapsEveryRuleState() {
    let table: [(ClosedLidPermissionState, ClosedLidSetupRuleStatus)] = [
      (.ready, .ready), (.allowedByOtherRule, .allowedByOtherRule), (.notInstalled, .missing),
      (.needsRepair, .needsRepair), (.blocked, .blocked), (.notAdmin, .notAdmin),
    ]
    for (state, expected) in table { #expect(ClosedLidSetupRuleStatus(state) == expected) }
  }

  @Test func encodesStableJSON() {
    let status = ClosedLidSetupStatus(
      rule: .allowedByOtherRule, script: .present, agent: .loaded, ruleInstalledByCompanion: false)
    #expect(
      status.jsonString
        == #"{"agent":"loaded","rule":"allowedByOtherRule","ruleInstalledByCompanion":false,"script":"present"}"#
    )
    #expect(status.isInstalled)
  }
}

struct ClosedLidSetupAssetTests {
  @Test func theBundledScriptMatchesTheCompiledInChecksumAndTheRepoCopy() throws {
    let assets = ClosedLidSetupAssets.bundled()
    #expect(
      digest(assets.script) == ClosedLidSetupAssets.expectedScriptSHA256,
      "packaging/mas/dilated-power changed: update ClosedLidSetupAssets.expectedScriptSHA256")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let source = try Data(contentsOf: repo.appendingPathComponent("packaging/mas/dilated-power"))
    #expect(assets.script == source)
  }

  @Test func theBundledAgentTemplateHasThePlaceholderAndTheInstalledScriptPath() {
    let plist = ClosedLidSetupAssets.bundled().plistTemplate
    #expect(
      plist.contains(
        "__HOME__/Library/Application Scripts/com.codeswhat.dilated.appstore/dilated-power"))
    #expect(plist.contains(ClosedLidSetupPaths.agentLabel))
  }

  @Test func verificationJSONReportsTheBundledAssets() {
    #expect(
      ClosedLidSetupAssets.bundled().verificationJSON
        == #"{"plistValid":true,"scriptMatches":true,"scriptSHA256":"\#(ClosedLidSetupAssets.expectedScriptSHA256)"}"#
    )
    let broken = ClosedLidSetupAssets(script: Data("x".utf8), plistTemplate: "")
    #expect(broken.verificationJSON.contains(#""scriptMatches":false"#))
    #expect(broken.verificationJSON.contains(#""plistValid":false"#))
  }

  @Test func pathsMatchWhatTheMacAppStoreBuildAndTheCheckScriptsUse() {
    let paths = ClosedLidSetupPaths(home: "/Users/a", uid: 7)
    #expect(
      paths.scriptPath
        == "/Users/a/Library/Application Scripts/com.codeswhat.dilated.appstore/dilated-power")
    #expect(
      paths.agentPlistPath
        == "/Users/a/Library/LaunchAgents/com.codeswhat.dilated.closed-lid-repair.plist")
    #expect(paths.agentTarget == "gui/7/com.codeswhat.dilated.closed-lid-repair")
    #expect(paths.sessionFile == "/Users/a/Library/Application Support/dilated-power/session")
  }

  @Test func theSharedRuleIsTheDirectBuildsRule() {
    #expect(ClosedLidPermission.rulePath == "/private/etc/sudoers.d/dilated")
    #expect(
      ClosedLidSetupPaths(home: "/Users/test", uid: 501).sessionLockFile
        == "/Users/test/Library/Application Support/Dilated/closed-lid-session.lock")
  }

  @Test func theSessionLockFollowsTheAppsStateDirectoryOverride() {
    let directory = "/tmp/dilated-state-override"
    let paths = ClosedLidSetupPaths(
      home: "/Users/test", uid: 501, stateDirectoryOverride: directory)
    #expect(
      paths.sessionLockFile
        == ClosedLidMarkerStore(
          directory: DilatedStateDirectory.resolve(
            environment: ["DILATED_STATE_DIR": directory],
            applicationSupport: URL(fileURLWithPath: "/Users/test/Library/Application Support"))
        ).lockFile.path)
    #expect(paths.sessionLockFile == "\(directory)/closed-lid-session.lock")
  }
}

struct ClosedLidSetupLiveFileSystemTests {
  @Test func liveFileSystemWritesAtomicallyWithModeAndRemovesEmptyFolders() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("closed-lid-setup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = LiveSetupFileSystem()
    let target = root.appendingPathComponent("a/b/script").path
    try fileSystem.writeAtomically(Data("one".utf8), to: target, mode: 0o755, directoryMode: 0o700)
    try fileSystem.writeAtomically(Data("two".utf8), to: target, mode: 0o755, directoryMode: 0o700)
    #expect(fileSystem.read(target) == Data("two".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: target)
    #expect((attributes[.posixPermissions] as? Int) == 0o755)
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: (target as NSString).deletingLastPathComponent)
    #expect(siblings == ["script"])
    fileSystem.removeDirectoryIfEmpty((target as NSString).deletingLastPathComponent)
    #expect(fileSystem.exists(target))
    try fileSystem.remove(target)
    try fileSystem.remove(target)
    fileSystem.removeDirectoryIfEmpty((target as NSString).deletingLastPathComponent)
    #expect(!fileSystem.exists((target as NSString).deletingLastPathComponent))
  }

  @Test(.timeLimit(.minutes(1)))
  func setupProcessReturnsPromptlyForFastAndTimedOutChildren() async {
    let fast = await SetupProcess.run("/usr/bin/true", [], timeout: 30)
    #expect(fast?.status == 0)
    #expect(fast?.timedOut == false)
    let slow = await SetupProcess.run("/bin/sleep", ["30"], timeout: 0.3)
    #expect(slow?.timedOut == true)
    #expect(await SetupProcess.run("/nonexistent/tool", []) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func setupProcessTerminatesTheChildWhenTheTaskIsCancelled() async throws {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("setup-started-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    // The child touches the marker once it's running, so the cancel can't beat the launch.
    let task = Task {
      await SetupProcess.run(
        "/bin/sh", ["-c", "touch '\(marker.path)'; exec sleep 30"], timeout: 30)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path), "The child never started.")
    let started = ContinuousClock.now
    task.cancel()
    let result = await task.value
    #expect(result != nil)
    #expect(result?.timedOut == false)
    #expect(started.duration(to: .now) < .seconds(10))
  }

  @Test(.timeLimit(.minutes(1)))
  func setupProcessCancelledBeforeLaunchReturnsNilAndStartsNothing() async {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("setup-never-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return await SetupProcess.run("/usr/bin/touch", [marker.path], timeout: 30)
    }
    task.cancel()
    #expect(await task.value == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
