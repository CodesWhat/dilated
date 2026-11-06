import AppIntents
import Foundation

#if !DILATED_CONTROL_EXTENSION
  import DilatedUI
#endif

struct SetAwakeControlIntent: SetValueIntent {
  static let title: LocalizedStringResource = "Set Keep Awake control"
  static let description = IntentDescription(
    "Start a 15-minute hold. Turning off ends all holds and pauses automation until you resume in Dilated."
  )
  static var supportedModes: IntentModes { .foreground }
  static let isDiscoverable = false
  @Parameter(title: "Keep awake") var value: Bool

  @MainActor func perform() async throws -> some IntentResult {
    #if DILATED_CONTROL_EXTENSION
      throw NSError(
        domain: "com.codeswhat.dilated.control", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Open Dilated to change its awake state."])
    #else
      try await AutomationService.shared.setAwakeFromControl(value)
    #endif
    return .result()
  }
}
