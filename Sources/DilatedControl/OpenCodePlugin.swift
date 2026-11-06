import Foundation

public struct OpenCodePluginInstallation {
  public let file: URL
  public let executable: URL
  private let marker = "// Dilated agent adapter v1\n"

  public init(file: URL, executable: URL) {
    self.file = file
    self.executable = executable
  }

  private func content() throws -> Data {
    let quoted = String(
      decoding: try JSONSerialization.data(
        withJSONObject: executable.path, options: .fragmentsAllowed), as: UTF8.self)
    let script = #"""
      import { spawn } from "node:child_process";
      const executable = \#(quoted);
      export const Dilated = async () => {
        const active = new Set();
        const pending = new Map();
        const valid = (id) => typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id);
        const send = (event, id) => new Promise((resolve) => {
          try {
            const child = spawn(executable, ["agent", "opencode-hook", "--pid", String(process.pid)], {
              stdio: ["pipe", "ignore", "ignore"], timeout: event === "UserPromptSubmit" ? 10000 : 3000,
            });
            child.once("error", () => resolve());
            child.once("close", () => resolve());
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify({ session_id: id, hook_event_name: event }));
          } catch { resolve(); }
        });
        const invoke = (event, id) => {
          const task = (pending.get(id) ?? Promise.resolve()).then(() => send(event, id));
          pending.set(id, task);
          return task.finally(() => { if (pending.get(id) === task) pending.delete(id); });
        };
        const end = async (id) => {
          if (active.delete(id)) await invoke("Stop", id);
        };
        return {
          event: async ({ event }) => {
            const properties = event?.properties;
            const id = properties?.sessionID ?? properties?.info?.id;
            if (!valid(id)) return;
            if (event.type === "session.status") {
              if (properties.status?.type === "busy" && !active.has(id)) {
                active.add(id);
                await invoke("UserPromptSubmit", id);
              } else if (properties.status?.type === "idle") await end(id);
            } else if (["session.idle", "session.error", "session.deleted"].includes(event.type)) await end(id);
          },
          "tool.execute.before": async ({ sessionID }) => {
            if (active.has(sessionID)) await invoke("PreToolUse", sessionID);
          },
          dispose: async () => { await Promise.all([...active].map(end)); },
        };
      };
      """#
    return Data((marker + script + "\n").utf8)
  }

  private func existing() throws -> Data? {
    FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
  }

  public func health() throws -> AgentHookInstallation.Health {
    guard let data = try existing() else { return .missing }
    return data == (try content()) ? .installed : .drifted
  }

  private func backup(_ data: Data) throws {
    let backup = file.deletingLastPathComponent().appendingPathComponent(
      "dilated-plugin-\(UUID().uuidString).backup")
    try data.write(to: backup, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
  }

  public func install() throws {
    let original = try existing()
    let data = try content()
    if original == data { return }
    if let original, !original.starts(with: Data(marker.utf8)) {
      throw InputError("A different plugin already uses this path. It wasn't changed.")
    }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if let original { try backup(original) }
    let destination = file.resolvingSymlinksInPath()
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  public func remove() throws {
    guard let original = try existing() else { return }
    guard original.starts(with: Data(marker.utf8)) else {
      throw InputError("This file isn't Dilated's plugin. It wasn't removed.")
    }
    try backup(original)
    try FileManager.default.removeItem(at: file)
  }
}
