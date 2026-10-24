import DilatedControl
import DilatedCore
import Foundation
import ServiceManagement
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
    #expect(operations == ["login", "cli"])
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

  private var app: URL { URL(fileURLWithPath: "/Applications/Dilated.app") }
  private func makeModel(_ directory: URL) -> AppModel {
    AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      helperInstallation: HelperInstallation(
        service: NoPackageHelper(),
        readPower: {
          .init(effectiveDisabled: false, storedDisabled: false)
        }))
  }
}

@MainActor private final class NoPackageHelper: HelperInstalling {
  var status: SMAppService.Status { .notRegistered }
  func register() throws {}
  func unregister() async throws {}
  func openApproval() {}
}
