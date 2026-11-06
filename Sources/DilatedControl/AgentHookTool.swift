import Foundation

public enum AgentHookTool: String, CaseIterable, Sendable {
  case claude, codex, opencode

  public var title: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    }
  }
  public var commandName: String { rawValue + "-hook" }
  var events: [String] {
    self == .codex
      ? ["UserPromptSubmit", "PreToolUse", "Stop", "Interrupt", "SessionEnd"]
      : ["UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd"]
  }
  func timeout(for event: String) -> Int {
    self == .codex && ["Interrupt", "SessionEnd"].contains(event) ? 3 : 10
  }
}
