import Foundation
import Observation
import Testing

@testable import DilatedUI

@MainActor struct AppUpdaterTests {
  @Test func installationWaitsForClosedLidAndHelperWork() {
    let activity = UpdateActivityFixture()
    let driver = UpdateDriverFixture()
    let updater = AppUpdater(driver: driver, activity: { activity.value })
    updater.start()
    #expect(driver.starts == 1)
    for value in [UpdateActivity.closedLid, .helperChange, .recovering] {
      activity.value = value
      updater.refreshActivity()
      #expect(!updater.canCheckForUpdates)
    }
    var installs = 0
    #expect(updater.postponeInstallation { installs += 1 })
    #expect(!updater.blocksNewWork)
    #expect(installs == 0)
    activity.value = .idle
    updater.refreshActivity()
    #expect(updater.blocksNewWork)
    #expect(installs == 1)
    updater.refreshActivity()
    #expect(installs == 1)
  }

  @Test func cancellationClearsDeferredInstallationAndAllowsWorkAgain() {
    let activity = UpdateActivityFixture()
    let updater = AppUpdater(driver: UpdateDriverFixture(), activity: { activity.value })
    updater.start()
    activity.value = .closedLid
    var installed = false
    #expect(updater.postponeInstallation { installed = true })
    updater.updateFinished(error: nil)
    activity.value = .idle
    updater.refreshActivity()
    #expect(!installed)
    #expect(!updater.blocksNewWork)
    #expect(updater.canCheckForUpdates)
    #expect(!updater.postponeInstallation {})
    #expect(updater.blocksNewWork)
    updater.updateFinished(error: nil)
    #expect(!updater.blocksNewWork)
  }

  @Test func launchPolicyRequiresAReleaseBundleWithSignedFeedConfiguration() {
    let info: [String: Any] = [
      "SUFeedURL": "https://dilated.codeswhat.com/updates/appcast.xml",
      "SUPublicEDKey": "ehOxBirzN5y9MqUzYKsrYwgn4MAle82Z3rQIvYpZlhY=",
      "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
      "DilatedUpdatesEnabled": true,
    ]
    let bundle = URL(fileURLWithPath: "/Applications/Dilated.app")
    #expect(UpdateLaunchPolicy.allows(arguments: ["DilatedApp"], bundleURL: bundle, info: info))
    for key in [
      "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction",
      "DilatedUpdatesEnabled",
    ] {
      var invalid = info
      invalid.removeValue(forKey: key)
      #expect(
        !UpdateLaunchPolicy.allows(arguments: ["DilatedApp"], bundleURL: bundle, info: invalid))
    }
    #expect(
      !UpdateLaunchPolicy.allows(
        arguments: ["DilatedApp", "--settings"], bundleURL: bundle, info: info))
    #expect(
      !UpdateLaunchPolicy.allows(
        arguments: ["DilatedApp"], bundleURL: URL(fileURLWithPath: "/tmp/debug"), info: info))
  }
}

@MainActor @Observable private final class UpdateActivityFixture {
  var value = UpdateActivity.idle
}

@MainActor private final class UpdateDriverFixture: UpdateDriving {
  weak var delegate: (any UpdateDriverDelegate)?
  var onChange: (() -> Void)?
  var canCheckForUpdates = true
  var automaticallyChecksForUpdates = false
  var starts = 0
  func start() throws { starts += 1 }
  func checkForUpdates() {}
}
