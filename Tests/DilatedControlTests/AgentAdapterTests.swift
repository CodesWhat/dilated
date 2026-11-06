import Foundation
import Testing

@testable import DilatedControl

struct AgentAdapterTests {
  @Test func codexConfigurationPreservesExistingHooksAndUsesInterruptTimeout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "adapter-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("hooks.json")
    let original = Data(
      #"{"description":"keep","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user"}]}]}}"#
        .utf8)
    try original.write(to: url)
    let installation = AgentHookInstallation(
      settingsURL: url,
      executable: URL(fileURLWithPath: "/Applications/Dilated's App.app/Contents/MacOS/dilated"),
      tool: .codex)
    try installation.install()
    #expect(try installation.health() == .installed)
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
    #expect(
      Set(hooks.keys) == Set(["UserPromptSubmit", "PreToolUse", "Stop", "Interrupt", "SessionEnd"]))
    for event in ["Interrupt", "SessionEnd"] {
      let handlers = try #require(hooks[event]?.first?["hooks"] as? [[String: Any]])
      #expect(handlers.first?["timeout"] as? Int == 3)
      #expect((handlers.first?["command"] as? String)?.contains("codex-hook") == true)
    }
    let installed = try Data(contentsOf: url)
    try installation.install()
    #expect(try Data(contentsOf: url) == installed)
    try installation.remove()
    #expect(
      (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
        == (try JSONSerialization.jsonObject(with: original) as? NSDictionary))
  }

  @Test func interruptIsSpecificToCodexAndEndHasNoPid() throws {
    let data = Data(#"{"session_id":"run1","hook_event_name":"Interrupt"}"#.utf8)
    let command = try AgentHookInput.command(data: data, pid: 42, tool: .codex)
    #expect(command.verb == .end && command.agent == "codex" && command.pid == nil)
    #expect(throws: (any Error).self) {
      try AgentHookInput.command(data: data, pid: 42, tool: .claude)
    }
  }
}
