import AppKit
import DilatedCore
import SwiftUI
import WidgetKit

@main struct DilatedControls: WidgetBundle {
  var body: some Widget { AwakeControl() }
}

struct AwakeControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: AwakeControlStateStore.controlKind, provider: AwakeControlValueProvider()
    ) { state in
      ControlWidgetToggle(isOn: state.awake, action: SetAwakeControlIntent()) {
        Label("Keep Awake", systemImage: "eye")
      } valueLabel: { awake in
        Text(awake ? "On" : state.paused ? "Paused" : "Off")
      }
    }
    .displayName("Keep Awake")
    .description(
      "Start a 15-minute hold. Turning off ends all holds and pauses automation. Resume automation in Dilated."
    )
  }
}

struct AwakeControlValue: Sendable {
  var awake = false
  var paused = false
}

struct AwakeControlValueProvider: ControlValueProvider {
  var previewValue: AwakeControlValue { .init() }

  func currentValue() async throws -> AwakeControlValue {
    guard let state = AwakeControlStateStore.shared()?.read() else { return .init() }
    let app = NSRunningApplication(processIdentifier: state.appPID)
    let live =
      app?.bundleIdentifier == AwakeControlStateStore.hostBundleID && app?.isTerminated == false
    return AwakeControlValue(
      awake: state.isAwake(at: Date(), hostIsRunning: live), paused: state.automationPaused)
  }
}
