import AppKit
import DilatedCore
import Observation
import ServiceManagement

@MainActor protocol HelperInstalling: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
  func openApproval()
}

@MainActor private final class SystemHelperInstallation: HelperInstalling {
  private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
  var status: SMAppService.Status { service.status }
  func register() throws {
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    guard path.hasPrefix("/Applications/"), path.hasSuffix(".app") else {
      throw HelperClientError.rejected("Move Dilated to Applications before setting up closed-lid.")
    }
    try service.register()
  }
  func unregister() async throws { try await service.unregister() }
  func openApproval() {
    SMAppService.openSystemSettingsLoginItems()
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}

@MainActor @Observable public final class HelperInstallation {
  public private(set) var status: SMAppService.Status
  public private(set) var busy = false
  public private(set) var lastError: String?
  @ObservationIgnored private let service: any HelperInstalling
  @ObservationIgnored private let readPower: () -> ClosedLidReadback

  public convenience init() { self.init(service: SystemHelperInstallation()) }
  init(
    service: any HelperInstalling,
    readPower: @escaping () -> ClosedLidReadback = NativeClosedLidPower.readback
  ) {
    self.service = service
    self.readPower = readPower
    status = service.status
  }
  public var statusCode: String {
    switch status {
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notRegistered: "notRegistered"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
  }
  public func refreshStatus() { status = service.status }
  public var statusText: String {
    switch status {
    case .enabled: "Approved"
    case .requiresApproval: "Needs approval in Login Items"
    case .notRegistered: "Not installed"
    case .notFound: "Helper not found"
    @unknown default: "Helper status unavailable"
    }
  }
  public var buttonTitle: String {
    switch status {
    case .enabled: "Repair helper"
    case .requiresApproval: "Open Login Items"
    default: "Set up closed-lid"
    }
  }

  public func reconcileAfterLaunch(controller: ClosedLidController) async {
    refreshStatus()
    guard status == .enabled, !busy else { return }
    do {
      try await controller.refresh()
    } catch HelperClientError.helperUpdate {
      await nextStep(controller: controller)
    } catch { lastError = error.localizedDescription }
  }

  public func nextStep(controller: ClosedLidController) async {
    guard !busy else { return }
    refreshStatus()
    if status == .requiresApproval {
      service.openApproval()
      return
    }
    busy = true
    lastError = nil
    defer {
      busy = false
      refreshStatus()
    }
    do {
      if status == .enabled {
        try await controller.disable()
        controller.invalidate()
        try await service.unregister()
      }
      try service.register()
      refreshStatus()
      if status == .requiresApproval { service.openApproval() }
      if status == .enabled { try await controller.refresh() }
    } catch {
      refreshStatus()
      if status == .requiresApproval {
        service.openApproval()
      } else {
        lastError = error.localizedDescription
      }
    }
  }

  public func remove(controller: ClosedLidController) async throws {
    guard !busy else { throw HelperClientError.rejected("The helper setup is still running.") }
    busy = true
    defer {
      busy = false
      refreshStatus()
    }
    refreshStatus()
    if status == .notRegistered {
      guard readPower().confirmedDisabled else {
        throw HelperClientError.rejected(
          "The helper isn't registered, but macOS hasn't confirmed normal sleep. Repair the helper before removing Dilated."
        )
      }
      controller.invalidate()
      return
    }
    try await controller.disable()
    controller.invalidate()
    try await service.unregister()
  }
}
