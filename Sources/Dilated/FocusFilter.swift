import AppIntents
import DilatedUI
import Foundation

struct FocusTriggerEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Awake rule")
  static let defaultQuery = FocusTriggerQuery()
  let id: UUID
  let name: String
  var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct FocusTriggerQuery: EntityQuery {
  @MainActor func entities(for identifiers: [UUID]) async throws -> [FocusTriggerEntity] {
    try await suggestedEntities().filter { identifiers.contains($0.id) }
  }
  @MainActor func suggestedEntities() async throws -> [FocusTriggerEntity] {
    try await AutomationService.shared.focusRuleChoices().map {
      FocusTriggerEntity(id: $0.id, name: $0.name)
    }
  }
}

struct SetAwakeFocusFilterIntent: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "Awake rule"
  static let description = IntentDescription(
    "Enable a Dilated rule during this Focus. Stop, paused rules and the automation switch still apply."
  )
  static var supportedModes: IntentModes { .background }
  @Parameter(title: "Rule") var rule: FocusTriggerEntity?
  @AppDependency var service: AutomationService
  var displayRepresentation: DisplayRepresentation {
    .init(title: "Awake rule", subtitle: "\(rule?.name ?? "None")")
  }
  @MainActor func perform() async throws -> some IntentResult {
    try await service.setFocusRule(id: rule?.id)
    return .result()
  }
}
