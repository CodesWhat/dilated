import AppKit
import DilatedCore
import OSLog
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
  @ObservationIgnored private let startupResetTimeout: Duration

  public convenience init() { self.init(service: SystemHelperInstallation()) }
  init(
    service: any HelperInstalling,
    readPower: @escaping () -> ClosedLidReadback = NativeClosedLidPower.readback,
    startupResetTimeout: Duration = .seconds(5)
  ) {
    self.service = service
    self.readPower = readPower
    self.startupResetTimeout = startupResetTimeout
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
      let replacing = status == .enabled
      if replacing {
        try await unregister(controller: controller)
      }
      try await register(replacing: replacing)
      refreshStatus()
      if status == .requiresApproval { service.openApproval() }
      if status == .enabled { try await waitUntilReady(controller: controller) }
    } catch {
      refreshStatus()
      if status == .requiresApproval {
        service.openApproval()
      } else {
        lastError = error.localizedDescription
      }
    }
  }

  private func register(replacing: Bool) async throws {
    for attempt in 0..<5 {
      try Task.checkCancellation()
      do {
        try service.register()
        return
      } catch {
        let failure = error as NSError
        guard replacing, attempt < 4, service.status == .notRegistered,
          failure.domain == SMAppServiceErrorDomain,
          failure.code == Int(POSIXErrorCode.EPERM.rawValue)
        else { throw error }
        // macOS can report completion before its unregister bookkeeping has settled.
        try await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func unregister(controller: ClosedLidController) async throws {
    let initiallyIdle = !controller.hasLease && !controller.pendingEnable && !controller.busy
    let initialReadback = initiallyIdle ? readPower() : nil
    let mayRecoverOff = initialReadback?.confirmedDisabled == true
    var recoveredOff = false
    do {
      try await controller.disable()
    } catch {
      let unreachable: Bool
      switch error {
      case HelperClientError.disconnected, HelperClientError.timedOut: unreachable = true
      default: unreachable = false
      }
      let stillIdle = !controller.hasLease && !controller.pendingEnable && !controller.busy
      let currentReadback = unreachable && mayRecoverOff && stillIdle ? readPower() : nil
      Logger(subsystem: HelperIdentity.appID, category: "HelperMaintenance").notice(
        "Lost helper transport during maintenance: initiallyIdle=\(initiallyIdle, privacy: .public), initialStored=\(String(describing: initialReadback?.storedDisabled), privacy: .public), initialEffective=\(String(describing: initialReadback?.effectiveDisabled), privacy: .public), stillIdle=\(stillIdle, privacy: .public), currentStored=\(String(describing: currentReadback?.storedDisabled), privacy: .public), currentEffective=\(String(describing: currentReadback?.effectiveDisabled), privacy: .public)"
      )
      guard unreachable, mayRecoverOff, stillIdle, currentReadback?.confirmedDisabled == true
      else { throw error }
      recoveredOff = true
    }
    try Task.checkCancellation()
    controller.invalidate()
    try await service.unregister()
    guard !recoveredOff || readPower().confirmedDisabled else {
      throw HelperClientError.rejected(
        "The helper was removed, but macOS hasn't confirmed sleep-disable is off. Repair the helper before continuing."
      )
    }
  }

  private func waitUntilReady(controller: ClosedLidController) async throws {
    let deadline = ContinuousClock.now.advanced(by: startupResetTimeout)
    while true {
      try await controller.refresh()
      guard let state = controller.state else { throw HelperClientError.invalidReply }
      if state.ready { return }
      guard state.phase == .starting || state.phase == .disabling else {
        throw HelperClientError.rejected(
          state.message ?? "The helper couldn't complete its startup reset.")
      }
      guard ContinuousClock.now < deadline else {
        throw HelperClientError.rejected(
          "The helper didn't finish its startup reset. Try setup again.")
      }
      try await Task.sleep(for: .milliseconds(100))
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
    if status == .requiresApproval {
      guard readPower().confirmedDisabled else {
        throw HelperClientError.rejected(
          "macOS hasn't confirmed sleep-disable is off. Approve or repair the helper before removal."
        )
      }
      controller.invalidate()
      try await service.unregister()
      guard readPower().confirmedDisabled else {
        throw HelperClientError.rejected(
          "The helper was removed, but macOS hasn't confirmed sleep-disable is off. Repair the helper before removing Dilated."
        )
      }
      return
    }
    if status == .notRegistered {
      guard readPower().confirmedDisabled else {
        throw HelperClientError.rejected(
          "The helper isn't registered, but macOS hasn't confirmed normal sleep. Repair the helper before removing Dilated."
        )
      }
      controller.invalidate()
      return
    }
    if status == .notFound {
      guard readPower().confirmedDisabled else {
        throw HelperClientError.rejected(
          "macOS can't find the helper and hasn't confirmed normal sleep. Repair the helper before removing Dilated."
        )
      }
      controller.invalidate()
      return
    }
    try await unregister(controller: controller)
  }
}
