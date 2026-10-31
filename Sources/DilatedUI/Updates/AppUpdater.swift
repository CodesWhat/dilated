import Foundation
import Observation

enum UpdateActivity { case starting, idle, closedLid, helperChange, recovering }

enum UpdateLaunchPolicy {
  static let feedURL = "https://dilated.codeswhat.com/updates/appcast.xml"
  static func allows(arguments: [String], bundleURL: URL, info: [String: Any]) -> Bool {
    arguments.count == 1 && bundleURL.pathExtension == "app"
      && info["SUFeedURL"] as? String == feedURL
      && (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }?.count == 32
      && info["SURequireSignedFeed"] as? Bool == true
      && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true
      && info["DilatedUpdatesEnabled"] as? Bool == true
  }
}

@MainActor protocol UpdateDriverDelegate: AnyObject {
  func mayCheckForUpdates() throws
  func postponeInstallation(_ install: @escaping () -> Void) -> Bool
  func updateAvailable()
  func updateWillRelaunch()
  func updateFinished(error: (any Error)?)
}

@MainActor protocol UpdateDriving: AnyObject {
  var delegate: (any UpdateDriverDelegate)? { get set }
  var onChange: (() -> Void)? { get set }
  var canCheckForUpdates: Bool { get }
  var automaticallyChecksForUpdates: Bool { get set }
  func start() throws
  func checkForUpdates()
}

@MainActor @Observable public final class AppUpdater: UpdateDriverDelegate {
  @ObservationIgnored private let driver: (any UpdateDriving)?
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored var activity: () -> UpdateActivity
  @ObservationIgnored private var pendingInstall: (() -> Void)?
  private var requestedStart = false
  private var observing = false
  private var started = false
  private var driverCanCheck = false
  private var currentActivity = UpdateActivity.starting
  public private(set) var blocksNewWork = false
  public private(set) var hasUpdate = false
  public private(set) var automaticallyChecksForUpdates = false
  public private(set) var errorMessage: String?
  public var isAvailable: Bool { driver != nil }
  public var canCheckForUpdates: Bool {
    isAvailable && currentActivity == .idle && !blocksNewWork && pendingInstall == nil
      && (!started || driverCanCheck)
  }
  public var statusText: String {
    guard isAvailable else { return "Updates aren't enabled in this test build." }
    if blocksNewWork { return "Installing the update. Dilated will reopen when it's ready." }
    if pendingInstall != nil { return "Waiting for closed-lid mode and helper changes to finish." }
    if currentActivity != .idle {
      return "Turn off closed-lid and finish helper changes before updating."
    }
    if let errorMessage { return errorMessage }
    if hasUpdate { return "An update is available. Review it when you're ready." }
    return "You choose when to download and install updates. Timers keep their original deadlines."
  }

  convenience init() {
    let allowed = UpdateLaunchPolicy.allows(
      arguments: CommandLine.arguments, bundleURL: Bundle.main.bundleURL,
      info: Bundle.main.infoDictionary ?? [:])
    self.init(driver: allowed ? SparkleDriver() : nil, activity: { .starting })
  }
  init(driver: (any UpdateDriving)?, activity: @escaping () -> UpdateActivity) {
    self.driver = driver
    self.activity = activity
    driver?.delegate = self
    driver?.onChange = { [weak self] in self?.refreshDriver() }
    refreshActivity()
    refreshDriver()
  }
  func start() {
    guard driver != nil else { return }
    requestedStart = !started
    if !observing {
      observing = true
      observeActivity()
    }
    refreshActivity()
  }
  func refreshActivity() {
    currentActivity = activity()
    if requestedStart, !started, currentActivity == .idle, !blocksNewWork {
      requestedStart = false
      startDriver()
    }
    if currentActivity == .idle, let install = pendingInstall {
      pendingInstall = nil
      blocksNewWork = true
      install()
    }
  }
  private func observeActivity() {
    withObservationTracking {
      _ = activity()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeActivity() }
    }
    refreshActivity()
  }
  private func startDriver() {
    let previous = canCheckForUpdates
    do {
      try driver?.start()
      started = true
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
    refreshDriver(previousAvailability: previous)
  }
  private func refreshDriver(previousAvailability: Bool? = nil) {
    let previous = previousAvailability ?? canCheckForUpdates
    driverCanCheck = driver?.canCheckForUpdates ?? false
    automaticallyChecksForUpdates = driver?.automaticallyChecksForUpdates ?? false
    if previous != canCheckForUpdates { onChange?() }
  }
  public func checkForUpdates() {
    refreshActivity()
    guard canCheckForUpdates else { return }
    if !started { startDriver() }
    guard started, driverCanCheck else { return }
    errorMessage = nil
    hasUpdate = false
    driver?.checkForUpdates()
    refreshDriver()
  }
  public func setAutomaticChecks(_ enabled: Bool) {
    driver?.automaticallyChecksForUpdates = enabled
    refreshDriver()
  }
  func mayCheckForUpdates() throws {
    guard activity() == .idle, !blocksNewWork, pendingInstall == nil else {
      throw NSError(
        domain: "DilatedUpdates", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Turn off closed-lid and finish helper changes before updating."
        ])
    }
  }
  func postponeInstallation(_ install: @escaping () -> Void) -> Bool {
    if activity() == .idle {
      blocksNewWork = true
      return false
    }
    pendingInstall = install
    return true
  }
  func updateAvailable() {
    hasUpdate = true
    refreshActivity()
  }
  func updateWillRelaunch() { blocksNewWork = true }
  func updateFinished(error: (any Error)?) {
    pendingInstall = nil
    blocksNewWork = false
    hasUpdate = false
    errorMessage =
      (error as NSError?)?.domain == "DilatedUpdates" ? nil : error?.localizedDescription
    refreshDriver()
  }
}
