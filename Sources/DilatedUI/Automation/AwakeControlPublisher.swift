import DilatedCore
import Foundation
import WidgetKit
import os

@MainActor final class AwakeControlPublisher {
  private let store: AwakeControlStateStore
  private let appPID: Int32
  private let reload: () -> Void
  private var lastPublished: AwakeControlState?
  private var reportedFailure = false

  init(store: AwakeControlStateStore, appPID: Int32, reload: @escaping () -> Void) {
    self.store = store
    self.appPID = appPID
    self.reload = reload
  }

  static func live(
    bundleID: String? = Bundle.main.bundleIdentifier,
    makeStore: () -> AwakeControlStateStore? = { AwakeControlStateStore.shared() },
    reload: @escaping () -> Void = {
      ControlCenter.shared.reloadControls(ofKind: AwakeControlStateStore.controlKind)
    }
  ) -> AwakeControlPublisher? {
    guard bundleID == "com.codeswhat.dilated" || bundleID == "com.codeswhat.dilated.appstore",
      let store = makeStore()
    else { return nil }
    return Self(store: store, appPID: ProcessInfo.processInfo.processIdentifier, reload: reload)
  }

  func publish(_ snapshot: EngineSnapshot) {
    let state = AwakeControlState(snapshot: snapshot, appPID: appPID)
    guard state != lastPublished else { return }
    do {
      try store.write(state)
      lastPublished = state
      reportedFailure = false
      reload()
    } catch {
      if !reportedFailure {
        Logger(subsystem: "com.codeswhat.dilated", category: "control").error(
          "Couldn't publish Control Center state: \(error.localizedDescription, privacy: .public)")
        reportedFailure = true
      }
    }
  }
}
