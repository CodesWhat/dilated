import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

private final class HookApp: @unchecked Sendable {
  var engine = WakeEngine()
  func send(_ request: ControlRequest) -> ControlResponse {
    ControlRouter.handle(request, engine: &engine)
  }
}

struct AgentHooksTests {

  @Test func hookLabelReachesHistoryAndStopBlocksLaterHooks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hook-engine-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = HookApp()
    let lifecycle = AgentLifecycle(stateDirectory: directory) { app.send($0) }
    let start = try ClaudeHookInput.command(
      data: Data(#"{"session_id":"run1","hook_event_name":"UserPromptSubmit"}"#.utf8), pid: 42)
    let response = try await lifecycle.run(start)
    #expect(response.ok)
    #expect(app.engine.holds.first?.label == "Agent claude · decided by: hook")
    _ = app.send(ControlRequest(action: .stopAll))
    #expect(!(try await lifecycle.run(start)).ok)
    let renew = try ClaudeHookInput.command(
      data: Data(#"{"session_id":"run1","hook_event_name":"PreToolUse"}"#.utf8), pid: 42)
    #expect(!(try await lifecycle.run(renew)).ok)
    #expect(app.engine.holds.isEmpty)
  }

  private func rig() throws -> (URL, ClaudeHookInstallation) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claude-hooks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (
      directory,
      ClaudeHookInstallation(
        settingsURL: directory.appendingPathComponent("settings.json"),
        executable: URL(fileURLWithPath: "/Applications/Dilated's App.app/Contents/MacOS/dilated"))
    )
  }
  @Test func installPreservesSettingsAndHooksAndIsIdempotent() throws {
    let (directory, installer) = try rig()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data(
      #"{"model":"test","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}"#
        .utf8)
    try original.write(to: installer.settingsURL)
    #expect(try installer.health() == .missing)
    try installer.install()
    #expect(try installer.health() == .installed)
    let installed = try Data(contentsOf: installer.settingsURL)
    #expect(String(decoding: installed, as: UTF8.self).contains("echo existing"))
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "backup" }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    try installer.install()
    #expect(try Data(contentsOf: installer.settingsURL) == installed)
    try installer.remove()
    #expect(try installer.health() == .missing)
    let removed = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as? NSDictionary)
    #expect(removed == (try JSONSerialization.jsonObject(with: original) as? NSDictionary))
  }
  @Test func missingFileAndDriftRepair() throws {
    let (directory, installer) = try rig()
    defer { try? FileManager.default.removeItem(at: directory) }
    try installer.install()
    #expect(try installer.health() == .installed)
    var root = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as? [String: Any])
    root["disableAllHooks"] = true
    try JSONSerialization.data(withJSONObject: root).write(to: installer.settingsURL)
    #expect(try installer.health() == .drifted)
    root.removeValue(forKey: "disableAllHooks")
    var hooks = try #require(root["hooks"] as? [String: Any])
    hooks.removeValue(forKey: "Stop")
    root["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: root).write(to: installer.settingsURL)
    #expect(try installer.health() == .drifted)
    try installer.install()
    #expect(try installer.health() == .installed)
  }
  @Test(arguments: ["", "{bad", "[]", #"{"hooks":7}"#, #"{"hooks":{"Stop":7}}"#])
  func invalidSettingsAreNeverOverwritten(text: String) throws {
    let (directory, installer) = try rig()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data(text.utf8)
    try original.write(to: installer.settingsURL)
    #expect(throws: (any Error).self) { try installer.install() }
    #expect(throws: (any Error).self) { try installer.remove() }
    #expect(try Data(contentsOf: installer.settingsURL) == original)
  }
  @Test func installationPreservesASymlinkedSettingsFile() throws {
    let (directory, original) = try rig()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("managed-settings.json")
    try Data(#"{"model":"keep"}"#.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: original.settingsURL, withDestinationURL: target)
    let installer = ClaudeHookInstallation(
      settingsURL: original.settingsURL, executable: original.executable)
    try installer.install()
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: original.settingsURL.path)
        == target.path)
    #expect(try installer.health() == .installed)
    #expect(String(decoding: try Data(contentsOf: target), as: UTF8.self).contains("claude-hook"))
  }

  @Test func hookInputUsesSessionIdentity() throws {
    let begin = try ClaudeHookInput.command(
      data: Data(#"{"session_id":"abc-123","hook_event_name":"UserPromptSubmit"}"#.utf8), pid: 42)
    #expect(begin.verb == .begin && begin.run == "abc-123" && begin.pid == 42)
    #expect(begin.decidedByHook)
    let end = try ClaudeHookInput.command(
      data: Data(#"{"session_id":"abc-123","hook_event_name":"Stop"}"#.utf8), pid: 42)
    #expect(end.verb == .end && end.pid == nil)
    #expect(throws: (any Error).self) {
      try ClaudeHookInput.command(
        data: Data(#"{"session_id":"../bad","hook_event_name":"UserPromptSubmit"}"#.utf8), pid: 42)
    }
  }
}
