import AppKit
import DilatedControl
import DilatedCore
import Foundation
import SwiftUI
import Testing
import ViewInspector

@testable import DilatedUI

private final class PermissionWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var _info: ClosedLidFileInfo?
  private var _content: Data?
  private var _probe = true
  private var _admin = true
  private var _recovery = ClosedLidSessionGuard.Recovery.clean
  private var _scripts: [String] = []
  private var _outcomes: [PrivilegedScriptOutcome] = []
  private var _acknowledged = true

  static let good = ClosedLidFileInfo(isRegularFile: true, owner: 0, group: 0, mode: 0o440)

  func set(
    info: ClosedLidFileInfo?? = nil, content: Data?? = nil, probe: Bool? = nil, admin: Bool? = nil,
    recovery: ClosedLidSessionGuard.Recovery? = nil, acknowledged: Bool? = nil
  ) {
    lock.withLock {
      if let info { _info = info }
      if let content { _content = content }
      if let probe { _probe = probe }
      if let admin { _admin = admin }
      if let recovery { _recovery = recovery }
      if let acknowledged { _acknowledged = acknowledged }
    }
  }
  func queue(_ outcome: PrivilegedScriptOutcome) { lock.withLock { _outcomes.append(outcome) } }
  var scripts: [String] { lock.withLock { _scripts } }
  var recovery: ClosedLidSessionGuard.Recovery { lock.withLock { _recovery } }
  var acknowledged: Bool { lock.withLock { _acknowledged } }
  func pop(_ script: String) -> PrivilegedScriptOutcome {
    lock.withLock {
      _scripts.append(script)
      return _outcomes.isEmpty ? .succeeded : _outcomes.removeFirst()
    }
  }
  func snapshot() -> (ClosedLidFileInfo?, Data?, Bool, Bool) {
    lock.withLock { (_info, _content, _probe, _admin) }
  }
}

private struct WorldRunner: PrivilegedScriptRunning {
  let world: PermissionWorld
  func run(script: String) async -> PrivilegedScriptOutcome { world.pop(script) }
}

private actor GateRunner: PrivilegedScriptRunning {
  private var continuation: CheckedContinuation<PrivilegedScriptOutcome, Never>?
  private var early: PrivilegedScriptOutcome?
  func run(script: String) async -> PrivilegedScriptOutcome {
    if let early { return early }
    return await withCheckedContinuation { continuation = $0 }
  }
  func open(_ outcome: PrivilegedScriptOutcome) {
    if let continuation {
      continuation.resume(returning: outcome)
      self.continuation = nil
    } else {
      early = outcome
    }
  }
}

private actor IdlePower: ClosedLidPowerControlling {
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
  }
  func readback() async -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)
  }
  func sleep() async throws {}
}

@MainActor private func makeWorld(_ state: ClosedLidPermissionState) -> PermissionWorld {
  let world = PermissionWorld()
  switch state {
  case .notInstalled: world.set(info: .some(nil), content: .some(nil), probe: false)
  case .allowedByOtherRule: world.set(info: .some(nil), content: .some(nil), probe: true)
  case .needsRepair:
    world.set(info: .some(PermissionWorld.good), content: .some(Data("junk\n".utf8)))
  case .blocked:
    world.set(
      info: .some(PermissionWorld.good), content: .some(ClosedLidPermission.ruleContent),
      probe: false)
  case .ready:
    world.set(info: .some(PermissionWorld.good), content: .some(ClosedLidPermission.ruleContent))
  case .notAdmin: world.set(admin: false)
  }
  return world
}

@MainActor private func makePermissionModel(_ world: PermissionWorld) -> ClosedLidPermissionModel {
  let permission = ClosedLidPermission(
    seams: .init(
      stat: { _ in world.snapshot().0 }, readFile: { _ in world.snapshot().1 },
      probe: { world.snapshot().2 }, isAdmin: { world.snapshot().3 }),
    runner: WorldRunner(world: world))
  return ClosedLidPermissionModel(
    permission: permission, recovery: { world.recovery },
    acknowledgeRestore: { world.acknowledged })
}

@MainActor private func makeAppModel(
  permission: ClosedLidPermissionModel, local: Bool, directory: URL
) -> AppModel {
  let controller =
    local
    ? ClosedLidController(
      transport: LocalClosedLidTransport(power: IdlePower(), tickInterval: .seconds(3600)),
      expectedBuild: { LocalClosedLidTransport.buildIdentity })
    : ClosedLidController()
  return AppModel(
    endpoint: .init(stateDirectory: directory), power: { .init() },
    closedLid: controller,
    closedLidPermission: permission)
}

private func texts(_ view: some View) throws -> [String] {
  try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
}

private func button(_ view: some View, _ title: String) throws -> InspectableView<ViewType.Button> {
  try view.inspect().find(ViewType.Button.self) {
    (try? $0.labelView().text().string()) == title
  }
}

private func buttonTitles(_ view: some View) throws -> [String] {
  // SettingsRow lays its controls out twice (wide and narrow), so each button appears twice.
  var seen: [String] = []
  for title in try view.inspect().findAll(ViewType.Button.self).compactMap({
    try? $0.labelView().text().string()
  }) where !seen.contains(title) { seen.append(title) }
  return seen
}

@MainActor private func settle(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<200 {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor struct ClosedLidPermissionUITests {
  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  @Test(arguments: [
    (ClosedLidPermissionState.notInstalled, "Closed-lid permission isn't set up", ["Set Up"]),
    (.needsRepair, "Closed-lid permission needs repair", ["Repair", "Remove"]),
    (.blocked, "macOS isn't honoring the permission", ["Repair", "Remove"]),
    (.ready, "Closed-lid permission is set up", ["Remove"]),
    (.notAdmin, "Closed-lid needs an administrator account", []),
    (.allowedByOtherRule, "Another app's sudo rule allows closed-lid", ["Set Up"]),
  ])
  func eachStateShowsPlainWordsAndTheRightButtons(
    state: ClosedLidPermissionState, title: String, actions: [String]
  ) async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let permission = makePermissionModel(makeWorld(state))
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    let view = ClosedLidSettings(model: model)
    let shown = try texts(view)
    #expect(shown.contains("PERMISSION"))
    #expect(shown.contains(title))
    #expect(!shown.contains("HELPER"))
    let titles = try buttonTitles(view).filter { ["Set Up", "Repair", "Remove"].contains($0) }
    #expect(titles == actions)
  }

  @Test func anotherAppsRuleIsUsableAndExplainsItself() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let permission = makePermissionModel(makeWorld(.allowedByOtherRule))
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    #expect(permission.state == .allowedByOtherRule)
    #expect(permission.state?.isUsable == true)
    #expect(!permission.canRemove)
    #expect(permission.setUpTitle == "Set Up")
    #expect(permission.summary == "Closed-lid works through another app's sudo rule.")
    #expect(
      try texts(ClosedLidSettings(model: model)).contains {
        $0.contains("Another app's sudo rule already allows this")
      })
    let response = await model.control(.init(action: .lidPermissionStatus))
    #expect(response.ok && response.lidPermission == "allowedByOtherRule")
  }

  @Test func statusAnswersWhileTheAdminPromptIsOpen() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = GateRunner()
    let world = makeWorld(.notInstalled)
    let permission = ClosedLidPermissionModel(
      permission: ClosedLidPermission(
        seams: .init(
          stat: { _ in world.snapshot().0 }, readFile: { _ in world.snapshot().1 },
          probe: { world.snapshot().2 }, isAdmin: { world.snapshot().3 }),
        runner: gate))
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    let install = Task { @MainActor in await model.control(.init(action: .lidPermissionInstall)) }
    await settle { permission.busy }
    let status = await model.control(.init(action: .lidPermissionStatus))
    #expect(status.ok)
    let second = await model.control(.init(action: .lidPermissionInstall))
    #expect(second.code == "unavailable")
    await gate.open(.cancelled)
    let finished = await install.value
    #expect(finished.code == "cancelled")
  }

  @Test func notAdminAndBlockedExplainThemselves() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (state, phrase) in [
      (ClosedLidPermissionState.notAdmin, "administrator"), (.blocked, "sudo isn't honoring"),
    ] {
      let permission = makePermissionModel(makeWorld(state))
      let model = makeAppModel(permission: permission, local: true, directory: directory)
      defer { model.shutdown() }
      await permission.refresh()
      #expect(try texts(ClosedLidSettings(model: model)).contains { $0.contains(phrase) })
    }
  }

  @Test func setUpRunsTheInstallScriptAndShowsReady() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.notInstalled)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    let view = ClosedLidSettings(model: model)
    world.set(
      info: .some(PermissionWorld.good), content: .some(ClosedLidPermission.ruleContent),
      probe: true)
    try button(view, "Set Up").tap()
    await settle { permission.state == .ready }
    #expect(permission.state == .ready)
    #expect(world.scripts.count == 1)
    #expect(world.scripts[0].contains("visudo"))
  }

  @Test func cancellingTheAdminPromptIsANoOp() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.notInstalled)
    world.queue(.cancelled)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    try button(ClosedLidSettings(model: model), "Set Up").tap()
    await settle { !world.scripts.isEmpty && !permission.busy }
    #expect(world.scripts.count == 1)
    #expect(permission.state == .notInstalled)
    #expect(permission.lastError == nil)
    #expect(model.message == nil)
  }

  @Test func aFailedInstallShowsTheErrorInline() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.notInstalled)
    world.queue(.failed("visudo said no"))
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    try button(ClosedLidSettings(model: model), "Set Up").tap()
    await settle { permission.lastError != nil }
    #expect(permission.lastError == "visudo said no")
    #expect(try texts(ClosedLidSettings(model: model)).contains("visudo said no"))
  }

  @Test func removeRunsTheRemoveScript() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.ready)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    let view = ClosedLidSettings(model: model)
    world.set(info: .some(nil), content: .some(nil), probe: false)
    try button(view, "Remove").tap()
    await settle { permission.state == .notInstalled }
    #expect(permission.state == .notInstalled)
    #expect(world.scripts.count == 1)
    #expect(world.scripts[0].contains("rm"))
  }

  @Test func aForeignDisableShowsAMessageWithNoAction() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.ready)
    world.set(recovery: .foreignSleepDisabled)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    let view = ClosedLidSettings(model: model)
    #expect(try texts(view).contains("Another app has turned off sleep"))
    #expect(!(try buttonTitles(view).contains("Restore normal sleep")))
  }

  @Test func aFailedRevertOffersRestoreNormalSleep() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.ready)
    world.set(recovery: .failed("sudo said no"))
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    await permission.refresh()
    let view = ClosedLidSettings(model: model)
    #expect(try texts(view).contains("Dilated couldn't restore normal sleep"))
    world.set(recovery: .reverted)
    try button(view, "Restore normal sleep").tap()
    await settle { !world.scripts.isEmpty && !permission.busy }
    #expect(world.scripts.count == 1)
    #expect(world.scripts[0].contains("/usr/bin/pmset -a disablesleep 0"))
    #expect(permission.recovery == .reverted)
    #expect(!(try buttonTitles(ClosedLidSettings(model: model)).contains("Restore normal sleep")))
  }

  @Test func restoreThatMacOSDoesNotConfirmStaysFailed() async throws {
    let world = makeWorld(.ready)
    world.set(recovery: .failed("sudo said no"), acknowledged: false)
    let permission = makePermissionModel(world)
    let result = await permission.restoreNormalSleep()
    #expect(result == .failed)
    #expect(permission.lastError != nil)
    #expect(permission.recovery == .failed("sudo said no"))
  }

  @Test func cancellingRestoreChangesNothing() async {
    let world = makeWorld(.ready)
    world.set(recovery: .failed("sudo said no"))
    world.queue(.cancelled)
    let permission = makePermissionModel(world)
    await permission.refresh()
    #expect(await permission.restoreNormalSleep() == .cancelled)
    #expect(permission.lastError == nil)
    #expect(permission.recovery == .failed("sudo said no"))
  }

  @Test func flagOffRendersTheOldHelperGroupUnchanged() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.ready)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: false, directory: directory)
    defer { model.shutdown() }
    let view = ClosedLidSettings(model: model)
    let shown = try texts(view)
    #expect(shown.contains("HELPER"))
    #expect(!shown.contains("PERMISSION"))
    #expect(shown.contains("Check helper status"))
    #expect(
      shown.contains(
        "Approve the signed background helper in Login Items. Regular awake holds work without it."
      ))
    #expect(!(try buttonTitles(view).contains("Remove")))
    #expect(world.scripts.isEmpty)
  }

  @Test func lidPermissionControlStatusInstallAndRemove() async throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.notInstalled)
    let permission = makePermissionModel(world)
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    var response = await model.control(.init(action: .lidPermissionStatus))
    #expect(response.ok && response.lidPermission == "notInstalled")
    world.queue(.cancelled)
    response = await model.control(.init(action: .lidPermissionInstall))
    #expect(response.ok && response.code == "cancelled")
    world.set(
      info: .some(PermissionWorld.good), content: .some(ClosedLidPermission.ruleContent),
      probe: true)
    response = await model.control(.init(action: .lidPermissionInstall))
    #expect(response.ok && response.lidPermission == "ready")
    world.queue(.failed("nope"))
    response = await model.control(.init(action: .lidPermissionRemove))
    #expect(!response.ok && response.message == "nope" && response.code == "permissionFailure")
    world.set(info: .some(nil), content: .some(nil), probe: false)
    response = await model.control(.init(action: .lidPermissionRemove))
    #expect(response.ok && response.lidPermission == "notInstalled")
  }

  @Test func helperStatusMapsToThePermissionStateWithADeprecationNote() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let permission = makePermissionModel(makeWorld(.ready))
    let model = makeAppModel(permission: permission, local: true, directory: directory)
    defer { model.shutdown() }
    let response = await model.control(.init(action: .helperStatus))
    #expect(response.ok)
    #expect(response.lidPermission == "ready")
    #expect(response.message?.contains("deprecated") == true)
  }

  @Test func lidPermissionControlIsUnavailableWhenTheFlagIsOff() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = makeWorld(.ready)
    let model = makeAppModel(
      permission: makePermissionModel(world), local: false, directory: directory)
    defer { model.shutdown() }
    let response = await model.control(.init(action: .lidPermissionInstall))
    #expect(!response.ok && response.code == "unavailable")
    #expect(world.scripts.isEmpty)
  }
}
