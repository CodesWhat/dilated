import DilatedCore
import Foundation
import ServiceManagement

@testable import DilatedUI

private struct NeverRunsScripts: PrivilegedScriptRunning {
  func run(script: String) async -> PrivilegedScriptOutcome { .failed("not expected") }
}

private struct FixtureUserScript: UserScriptLaunching {
  let result: UserScriptRun
  func run(arguments: [String]) async -> UserScriptRun {
    result
  }
}

/// A permission model whose channel-specific permission probe passes.
@MainActor func readyPermissionModel() -> ClosedLidPermissionModel {
  ClosedLidPermissionModel(
    permission: ClosedLidPermission(
      seams: .init(
        stat: { _ in ClosedLidFileInfo(isRegularFile: true, owner: 0, group: 0, mode: 0o440) },
        readFile: { _ in ClosedLidPermission.ruleContent }, probe: { true }, isAdmin: { true }),
      runner: NeverRunsScripts()),
    scriptPermission: ClosedLidScriptPermission(
      launcher: FixtureUserScript(result: .finished(output: "ok\n", failureStatus: nil))))
}

/// A permission model with no rule installed. Any admin prompt it tries to run fails the test.
@MainActor func missingPermissionModel() -> ClosedLidPermissionModel {
  ClosedLidPermissionModel(
    permission: ClosedLidPermission(
      seams: .init(
        stat: { _ in nil }, readFile: { _ in nil }, probe: { false }, isAdmin: { true }),
      runner: NeverRunsScripts()),
    scriptPermission: ClosedLidScriptPermission(launcher: FixtureUserScript(result: .missing)))
}

#if MAS_CHANNEL
  /// The Mac App Store build has no helper migration, so the injected value is always nil.
  @MainActor func inertMigration(_ directory: URL) -> HelperMigrationInjection? { nil }
#else
  @MainActor final class FakeHelperRegistration: HelperUnregistering {
    var status: SMAppService.Status
    var unregisterError: (any Error)?
    var unregisterCalls = 0
    /// Called when `unregister()` succeeds, so a test can flip the fake launchd state with it.
    var onUnregister: (() -> Void)?
    init(status: SMAppService.Status) { self.status = status }
    func unregister() async throws {
      unregisterCalls += 1
      if let unregisterError { throw unregisterError }
      status = .notRegistered
      onUnregister?()
    }
  }

  /// A migration that finds nothing to do, for tests that call `AppModel.begin()`.
  @MainActor func inertMigration(_ directory: URL) -> HelperMigration {
    HelperMigration(
      service: FakeHelperRegistration(status: .notRegistered), stateDirectory: directory,
      jobState: { .absent }, revertSleep: { true })
  }
#endif

private actor IdleLidPower: ClosedLidPowerControlling {
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
  }
  func readback() async -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)
  }
  func sleep() async throws {}
}

/// A closed-lid controller that never runs sudo, for tests that call `AppModel.begin()`.
@MainActor func inertClosedLid() -> ClosedLidController {
  ClosedLidController(
    transport: LocalClosedLidTransport(power: IdleLidPower(), tickInterval: .seconds(3600)))
}
