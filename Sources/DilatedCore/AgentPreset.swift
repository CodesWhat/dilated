import Foundation

public enum AgentPreset {
  public static func rule(process: String) -> TriggerRule {
    TriggerRule(
      name: "Agent \(process) · decided by: CPU",
      criteria: [
        .process(name: process), .cpu(percent: 20, atLeast: true),
      ])
  }
}
