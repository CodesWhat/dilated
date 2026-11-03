import Foundation

@MainActor public protocol UpdateDriverDelegate: AnyObject {
  func mayCheckForUpdates() throws
  func postponeInstallation(_ install: @escaping () -> Void) -> Bool
  func updateAvailable()
  func updateWillRelaunch()
  func updateFinished(error: (any Error)?)
}

@MainActor public protocol UpdateDriving: AnyObject {
  var delegate: (any UpdateDriverDelegate)? { get set }
  var onChange: (() -> Void)? { get set }
  var canCheckForUpdates: Bool { get }
  var automaticallyChecksForUpdates: Bool { get set }
  func start() throws
  func checkForUpdates()
}

public enum UpdateDriverFactory {
  @MainActor public static func makeDriver() -> (any UpdateDriving)? {
    #if MAS_CHANNEL
      return nil
    #else
      return SparkleDriver()
    #endif
  }
}
