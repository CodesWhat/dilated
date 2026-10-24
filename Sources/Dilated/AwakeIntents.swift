import AppIntents
import DilatedControl
import DilatedUI
import Foundation

struct StartAwakeIntent: AppIntent {
  static let title: LocalizedStringResource = "Start keeping awake"
  static let description = IntentDescription(
    "Keep the Mac awake, allowing display sleep by default. Stop pauses automation until you resume it in Dilated."
  )
  static var supportedModes: IntentModes { .background }
  @AppDependency var service: AutomationService
  @Parameter(title: "Duration in minutes", description: "Leave empty to keep awake indefinitely.")
  var minutes: Double?
  @Parameter(title: "Allow display sleep", default: true) var allowDisplaySleep: Bool
  static var parameterSummary: some ParameterSummary {
    Summary("Keep the Mac awake") {
      \.$minutes
      \.$allowDisplaySleep
    }
  }
  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
    if let minutes, !minutes.isFinite || minutes <= 0 || minutes > 5_259_600 {
      throw InputError(
        "Duration must be positive and no more than ten years. Leave it empty for indefinite.")
    }
    let id = try await service.start(
      duration: minutes.map { $0 * 60 }, displayAwake: !allowDisplaySleep)
    return .result(value: id.uuidString)
  }
}

struct StopAwakeIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop keeping awake"
  static let description = IntentDescription(
    "End all app-managed awake holds and pause automation until you choose Resume automation in Dilated."
  )
  static var supportedModes: IntentModes { .background }
  @AppDependency var service: AutomationService
  @MainActor func perform() async throws -> some IntentResult {
    try await service.stop()
    return .result()
  }
}

struct AwakeStatusIntent: AppIntent {
  static let title: LocalizedStringResource = "Get awake status"
  static let description = IntentDescription(
    "Get active holds, deadlines, automation pause and the last observed helper state.")
  static var supportedModes: IntentModes { .background }
  @AppDependency var service: AutomationService
  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: try await service.status())
  }
}

struct SetClosedLidIntent: AppIntent {
  static let title: LocalizedStringResource = "Set closed-lid mode"
  static let description = IntentDescription(
    "Change closed-lid for a specific active hold. Requires previous helper approval and battery warning review. Never changes future defaults."
  )
  static var supportedModes: IntentModes { .background }
  @AppDependency var service: AutomationService
  @Parameter(title: "Hold ID", description: "Use the ID returned by Start keeping awake.")
  var holdID: String
  @Parameter(title: "Enable closed-lid", default: true) var enabled: Bool
  static var parameterSummary: some ParameterSummary {
    Summary("Set closed-lid for \(\.$holdID)") { \.$enabled }
  }
  @MainActor func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: holdID) else {
      throw InputError("Hold ID must be a UUID returned by Dilated.")
    }
    try await service.setClosedLid(id: id, enabled: enabled)
    return .result()
  }
}

struct DilatedShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartAwakeIntent(), phrases: ["Keep my Mac awake with \(.applicationName)"],
      shortTitle: "Keep awake", systemImageName: "eye")
    AppShortcut(
      intent: StopAwakeIntent(), phrases: ["Stop keeping awake with \(.applicationName)"],
      shortTitle: "Stop keeping awake", systemImageName: "stop.circle")
    AppShortcut(
      intent: AwakeStatusIntent(), phrases: ["Get my \(.applicationName) awake status"],
      shortTitle: "Awake status", systemImageName: "info.circle")
    AppShortcut(
      intent: SetClosedLidIntent(), phrases: ["Set closed-lid with \(.applicationName)"],
      shortTitle: "Set closed-lid", systemImageName: "laptopcomputer")
  }
}
