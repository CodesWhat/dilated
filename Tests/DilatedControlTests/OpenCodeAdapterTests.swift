import Foundation
import Testing

@testable import DilatedControl

struct OpenCodeAdapterTests {
  @Test(arguments: [false, true])
  func installedModuleUsesSessionEventsAndSerializesEachSession(missingCLI: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("dilated.js")
    let executable = directory.appendingPathComponent("fake cli's")
    try Data(
      "#!/bin/sh\n/bin/cat >> \"$DILATED_ADAPTER_LOG\"\nprintf '\\n' >> \"$DILATED_ADAPTER_LOG\"\n"
        .utf8
    ).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let installation = OpenCodePluginInstallation(file: file, executable: executable)
    try installation.install()
    #expect(try installation.health() == .installed)
    let original = try Data(contentsOf: file)
    if missingCLI { try FileManager.default.removeItem(at: executable) }
    try installation.install()
    #expect(try Data(contentsOf: file) == original)
    try Data(#"{"type":"module"}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
    let harness = directory.appendingPathComponent("harness.js")
    try Data(
      #"""
      import { pathToFileURL } from "node:url";
      const deadline = setTimeout(() => process.exit(2), 10000);
      try {
        const { Dilated } = await import(pathToFileURL(process.argv[2]).href);
        const hooks = await Dilated();
        const status = (id, type) => hooks.event({event: {type: "session.status", properties: {sessionID: id, status: {type}}}});
        await status("run1", "busy");
        await status("run1", "busy");
        await hooks["tool.execute.before"]({sessionID: "run1"});
        await status("run1", "idle");
        await status("run2", "busy");
        await hooks.dispose();
        await status("bad/id", "busy");
        await Promise.all([status("race", "busy"), status("race", "idle")]);
      } finally { clearTimeout(deadline); }
      """#.utf8
    ).write(to: harness)
    let output = directory.appendingPathComponent("events.jsonl")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      ProcessInfo.processInfo.environment["DILATED_JS_RUNTIME"] ?? "node", harness.path, file.path,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "DILATED_ADAPTER_LOG": output.path
    ]) { _, new in new }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    if missingCLI {
      #expect(!FileManager.default.fileExists(atPath: output.path))
      return
    }
    let events = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
    }
    #expect(
      events.compactMap { $0["hook_event_name"] } == [
        "UserPromptSubmit", "PreToolUse", "Stop", "UserPromptSubmit", "Stop", "UserPromptSubmit",
        "Stop",
      ])
    #expect(events.suffix(2).allSatisfy { $0["session_id"] == "race" })
    try installation.remove()
    #expect(try installation.health() == .missing)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasSuffix(".backup")
      })
  }

  @Test func ownedPluginRepairBacksUpEditsAndPreservesSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-repair-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("managed.js")
    let original = OpenCodePluginInstallation(
      file: target, executable: URL(fileURLWithPath: "/usr/bin/true"))
    try original.install()
    let link = directory.appendingPathComponent("dilated.js")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let installation = OpenCodePluginInstallation(
      file: link, executable: URL(fileURLWithPath: "/usr/bin/true"))
    let modified = try Data(contentsOf: target) + Data("// changed\n".utf8)
    try modified.write(to: target)
    #expect(try installation.health() == .drifted)
    try installation.install()
    #expect(try installation.health() == .installed)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "backup" }
    #expect(try backups.contains { try Data(contentsOf: $0) == modified })
    try installation.remove()
    #expect(!FileManager.default.fileExists(atPath: link.path))
    #expect(FileManager.default.fileExists(atPath: target.path))
  }

  @Test func foreignPluginCannotBeOverwrittenOrRemoved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("dilated.js")
    let original = Data("export const Mine = () => ({});".utf8)
    try original.write(to: file)
    let installation = OpenCodePluginInstallation(
      file: file, executable: URL(fileURLWithPath: "/usr/bin/true"))
    #expect(throws: (any Error).self) { try installation.install() }
    #expect(throws: (any Error).self) { try installation.remove() }
    #expect(try Data(contentsOf: file) == original)
  }
}
