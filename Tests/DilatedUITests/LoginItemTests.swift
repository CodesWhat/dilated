import AppKit
import ServiceManagement
import Testing

@testable import DilatedUI

@MainActor struct LoginItemTests {
  @Test func registrationFailureIsVisibleAndApprovalOpensSettings() {
    let service = LoginServiceFixture()
    let login = LoginItem(service: service)
    login.toggle()
    #expect(login.lastError?.contains("Registration denied") == true)
    service.state = .requiresApproval
    login.toggle()
    #expect(service.openedSettings)
    #expect(login.menuState == .mixed)
  }
}

@MainActor private final class LoginServiceFixture: LoginItemService {
  var state = SMAppService.Status.notRegistered
  var status: SMAppService.Status { state }
  var openedSettings = false
  func register() throws {
    throw NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
  }
  func unregister() throws { state = .notRegistered }
  func openSystemSettings() { openedSettings = true }
}
