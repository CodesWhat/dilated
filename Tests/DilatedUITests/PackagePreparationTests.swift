import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct PackagePreparationTests {
  @Test func controlAcknowledgementIdentifiesOnlyThePreparedApp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(directory)
    defer { model.shutdown() }
    let response = await model.control(.init(action: .prepareUpdate))
    #expect(response.ok)
    #expect(response.appPID == ProcessInfo.processInfo.processIdentifier)
  }
  @Test func packageUpdateKeepsOnlyTimersAndDoesNotRemoveLoginOrCLI() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(directory)
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 120)
    model.start()
    let timer = try #require(model.engine.holds.first { $0.expiry != nil })
    var removed = false
    let ready = await model.prepareForPackage(
      .update, app: app, removeLoginItem: { removed = true }, removeCommandLine: { removed = true })
    #expect(ready)
    #expect(!removed)
    let restored = try StateStore(directory: directory).load()
    #expect(restored.holds == [timer])
    #expect(restored.automationPaused)
    #expect(
      (try? PackageHandoffStore(directory: directory).requirePrepared(app: app))?.intent == .update)
    #expect(!(await model.control(.init(action: .start, duration: 60))).ok)
  }

  @Test func packageRemovalClearsTimersAndRemovesOnlyOwnedIntegration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(directory)
    defer { model.shutdown() }
    model.start(duration: 120)
    var operations: [String] = []
    #expect(
      await model.prepareForPackage(
        .uninstall, app: app, removeLoginItem: { operations.append("login") },
        removeCommandLine: { operations.append("cli") }))
    #if MAS_CHANNEL
      #expect(operations == ["login"])
    #else
      #expect(operations == ["login", "cli"])
    #endif
    #expect(model.history.records.first?.endReason?.rawValue == "packageRemoval")
    #expect(try StateStore(directory: directory).load().holds.isEmpty)
    #expect(
      (try? PackageHandoffStore(directory: directory).requirePrepared(app: app))?.intent
        == .uninstall)
  }

  @Test func failedIntegrationRemovalLeavesAppOpenWithoutPackagePermission() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(directory)
    defer { model.shutdown() }
    model.start(duration: 120)
    #expect(
      !(await model.prepareForPackage(
        .uninstall, app: app, removeLoginItem: { throw InputError("login removal failed") },
        removeCommandLine: {})))
    #expect(model.engine.holds.count == 1)
    #expect(model.message?.contains("login removal failed") == true)
    #expect(throws: (any Error).self) {
      try PackageHandoffStore(directory: directory).requirePrepared(app: app)
    }
  }

  @Test func packageRemovalLeavesTheSudoRuleAloneUnlessAsked() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = RuleWorld(outcome: .succeeded)
    let model = makeModel(directory, permission: world.model())
    defer { model.shutdown() }
    #expect(
      await model.prepareForPackage(
        .uninstall, app: app, removeLoginItem: {}, removeCommandLine: {}))
    #expect(world.scripts.isEmpty && world.installed)
    #expect(model.message?.contains("--remove-lid-permission") == true)
  }

  @Test func packageRemovalExplainsTheAvailablePermissionRemovalPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = RuleWorld(outcome: .succeeded)
    let permission = world.model()
    await permission.refresh()
    let model = makeModel(directory, permission: permission)
    defer { model.shutdown() }
    #expect(
      await model.prepareForPackage(
        .uninstall, app: app, removeLoginItem: {}, removeCommandLine: {}))
    #if MAS_CHANNEL
      #expect(!permission.canRemove)
      #expect(model.message?.contains("dilated lid-permission remove") == false)
    #else
      #expect(model.message?.contains("dilated lid-permission remove") == true)
      #expect(model.message?.contains("Settings") == true)
    #endif
  }

  @Test func packageRemovalWithPermissionFlagFollowsChannelSetupPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = RuleWorld(outcome: .succeeded)
    let model = makeModel(directory, permission: world.model())
    defer { model.shutdown() }
    let response = await model.control(.init(action: .prepareUninstall, removeLidPermission: true))
    #if MAS_CHANNEL
      #expect(!response.ok)
      #expect(world.scripts.isEmpty && world.installed)
      #expect(response.message?.contains("Dilated Closed-Lid Setup") == true)
      #expect(throws: (any Error).self) {
        try PackageHandoffStore(directory: directory).requirePrepared(app: app)
      }
    #else
      #expect(response.ok)
      #expect(world.scripts.count == 1 && !world.installed)
    #endif
  }

  @Test(arguments: [PrivilegedScriptOutcome.cancelled, .failed("sudoers is read-only")])
  func aCancelledOrFailedRuleRemovalLeavesTheAppOpenAndUnprepared(
    outcome: PrivilegedScriptOutcome
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = RuleWorld(outcome: outcome)
    let model = makeModel(directory, permission: world.model())
    defer { model.shutdown() }
    model.start(duration: 120)
    #expect(
      !(await model.prepareForPackage(
        .uninstall, app: app, removeLidPermission: true, removeLoginItem: {},
        removeCommandLine: {})))
    #expect(model.engine.holds.count == 1 && world.installed)
    #expect(throws: (any Error).self) {
      try PackageHandoffStore(directory: directory).requirePrepared(app: app)
    }
  }

  @Test func updatePreparationTurnsAnActiveClosedLidSessionOffThroughTheSudoPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let power = SessionPower()
    let controller = ClosedLidController(
      transport: LocalClosedLidTransport(
        power: power,
        // Fixed readings: CI runners have no battery or thermal data, which the real reader
        // reports as unavailable and the governor refuses.
        environment: {
          ClosedLidEnvironment(powerSource: .ac, thermal: .nominal, lidClosed: false)
        },
        tickInterval: .seconds(3600)))
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() }, closedLid: controller,
      helperMigration: inertMigration(directory))
    defer { model.shutdown() }
    model.start(duration: 120)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    #expect(await power.disabled)
    #expect(!(await model.prepareForPackage(.update, app: app)))
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: false)
    #expect(await model.prepareForPackage(.update, app: app))
    #expect(!(await power.disabled))
  }

  private var app: URL { URL(fileURLWithPath: "/Applications/Dilated.app") }
  private func makeModel(
    _ directory: URL, permission: ClosedLidPermissionModel? = nil
  ) -> AppModel {
    AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: inertClosedLid(), helperMigration: inertMigration(directory),
      closedLidPermission: permission)
  }
}

private actor SessionPower: ClosedLidPowerControlling {
  private(set) var disabled = false
  func setSleepDisabled(_ value: Bool) async throws -> ClosedLidReadback {
    disabled = value
    return ClosedLidReadback(effectiveDisabled: value, storedDisabled: value)
  }
  func readback() async -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
  }
  func sleep() async throws {}
}

/// A sudo rule that is installed until the (fake) admin prompt removes it.
private final class RuleWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var present = true
  private var ran: [String] = []
  private let outcome: PrivilegedScriptOutcome
  init(outcome: PrivilegedScriptOutcome) { self.outcome = outcome }
  var installed: Bool { lock.withLock { present } }
  var scripts: [String] { lock.withLock { ran } }

  private struct Runner: PrivilegedScriptRunning {
    let world: RuleWorld
    func run(script: String) async -> PrivilegedScriptOutcome {
      world.lock.withLock {
        world.ran.append(script)
        if world.outcome == .succeeded { world.present = false }
      }
      return world.outcome
    }
  }

  @MainActor func model() -> ClosedLidPermissionModel {
    ClosedLidPermissionModel(
      permission: ClosedLidPermission(
        seams: .init(
          stat: { [self] _ in
            installed
              ? ClosedLidFileInfo(isRegularFile: true, owner: 0, group: 0, mode: 0o440) : nil
          },
          readFile: { [self] _ in installed ? ClosedLidPermission.ruleContent : nil },
          probe: { [self] in installed }, isAdmin: { true }),
        runner: Runner(world: self)))
  }
}
