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

struct FakeLaunchd: LaunchAgentControlling {
  let log: SetupLog
  var loaded: @Sendable () -> Bool = { false }
  var bootstrapFails = false

  func bootstrap(domain: String, plistPath: String) async throws {
    log.add("bootstrap \(domain)")
    if bootstrapFails { throw ClosedLidSetupLiveError(message: "boom") }
  }
  func bootout(target: String) async { log.add("bootout \(target)") }
  func isLoaded(target: String) async -> Bool { loaded() }
}

struct FakePower: PowerScriptRunning {
  let log: SetupLog
  var fails = false
  func off(scriptPath: String) async throws {
    log.add("power off")
    if fails { throw ClosedLidSetupLiveError(message: "nope") }
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
    powerFails: Bool = false, bootstrapFails: Bool = false,
    assets: ClosedLidSetupAssets? = nil
  ) {
    let log = log
    files = FakeSetupFiles(log: log)
    rule = FakeRule(
      state: ruleState, log: log, afterInstall: afterInstall, afterRemove: afterRemove)
    var launchd = FakeLaunchd(log: log)
    launchd.bootstrapFails = bootstrapFails
    setup = ClosedLidSetup(
      paths: paths,
      assets: assets
        ?? ClosedLidSetupAssets(
          script: scriptBytes, plistTemplate: templateText,
          expectedScriptSHA256: digest(scriptBytes)),
      files: files, launchd: launchd, power: FakePower(log: log, fails: powerFails), rule: rule)
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
        "bootout gui/501/com.codeswhat.dilated.closed-lid-repair",
        "remove \(p.agentPlistPath)",
        "remove \(p.scriptPath)",
        "rmdir \(p.scriptsDirectory)",
        "rule remove",
        "remove \(p.stateFile)",
        "rmdir \(p.stateDirectory)",
      ])
  }

  @Test func revertsAnActiveSessionBeforeAnythingElse() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    #expect(await rig.setup.remove() == .completed)
    #expect(rig.log.events.first == "power off")
    #expect(rig.log.events[1].hasPrefix("bootout"))
  }

  @Test func doesNotRunOffWithoutASession() async {
    let rig = Rig(rule: .ready)
    installed(rig, recordRule: false)
    _ = await rig.setup.remove()
    #expect(!rig.log.events.contains("power off"))
  }

  @Test func stopsWhenTheSessionCannotBeReverted() async {
    let rig = Rig(rule: .ready, powerFails: true)
    installed(rig, recordRule: true)
    rig.files.put(rig.paths.sessionFile, Data("123 Mon".utf8))
    guard case .failed = await rig.setup.remove() else {
      Issue.record("expected a failure")
      return
    }
    #expect(rig.log.events == ["power off"])
    #expect(rig.files.entry(rig.paths.scriptPath) != nil)
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
}
