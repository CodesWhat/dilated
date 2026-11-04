import Foundation

public struct ClaudeHookInstallation {
  public enum Health: String, Sendable { case missing, installed, drifted }
  public let settingsURL: URL
  public let executable: URL
  private static let events = [
    "UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd",
  ]
  private static let marker = " agent claude-hook --pid "

  public init(settingsURL: URL, executable: URL) {
    self.settingsURL = settingsURL
    self.executable = executable
  }

  private var command: String {
    let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    return "exec " + quoted + Self.marker + "\"$PPID\""
  }

  private func read() throws -> (Data?, [String: Any]) {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (nil, [:]) }
    let data = try Data(contentsOf: settingsURL)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InputError("Claude settings must be a JSON object. The file wasn't changed.")
    }
    if let hooks = root["hooks"] {
      guard let events = hooks as? [String: Any] else {
        throw InputError("Claude hooks must be an object.")
      }
      for value in events.values {
        guard let groups = value as? [[String: Any]],
          groups.allSatisfy({ $0["hooks"] is [[String: Any]] })
        else {
          throw InputError("Claude hook entries must contain an array of handlers.")
        }
      }
    }
    return (data, root)
  }

  private func owns(_ handler: [String: Any]) -> Bool {
    handler["type"] as? String == "command"
      && (handler["command"] as? String)?.contains(Self.marker) == true
  }

  public func health() throws -> Health {
    let (_, root) = try read()
    let events = root["hooks"] as? [String: [[String: Any]]] ?? [:]
    var found = 0
    var valid = 0
    for (event, groups) in events {
      for group in groups {
        for handler in group["hooks"] as? [[String: Any]] ?? [] where owns(handler) {
          found += 1
          if Self.events.contains(event), handler["command"] as? String == command,
            handler["async"] as? Bool != true, handler["timeout"] as? Int == 10,
            group["matcher"] == nil || group["matcher"] as? String == "*"
          {
            valid += 1
          }
        }
      }
    }
    guard found > 0 else { return .missing }
    let complete = Self.events.allSatisfy { event in
      (events[event] ?? []).contains { group in
        (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
      }
    }
    return complete && found == Self.events.count && valid == found
      && root["disableAllHooks"] as? Bool != true ? .installed : .drifted
  }

  public func install() throws {
    if try health() == .installed { return }
    try change(install: true)
  }

  public func remove() throws { try change(install: false) }

  private func change(install: Bool) throws {
    let (original, initial) = try read()
    var root = initial
    var events = root["hooks"] as? [String: [[String: Any]]] ?? [:]
    for (event, groups) in events {
      let retained = groups.compactMap { group -> [String: Any]? in
        let handlers = group["hooks"] as? [[String: Any]] ?? []
        let kept = handlers.filter { !owns($0) }
        if kept.count == handlers.count { return group }
        guard !kept.isEmpty else { return nil }
        var result = group
        result["hooks"] = kept
        return result
      }
      if retained.isEmpty { events.removeValue(forKey: event) } else { events[event] = retained }
    }
    if install {
      for event in Self.events {
        events[event, default: []].append([
          "hooks": [["type": "command", "command": command, "timeout": 10]]
        ])
      }
    }
    if events.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = events }
    if NSDictionary(dictionary: root) == NSDictionary(dictionary: initial) { return }
    let parent = settingsURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let original {
      let backup = parent.appendingPathComponent("dilated-settings-\(UUID().uuidString).backup")
      try original.write(to: backup, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
  }
}

public enum ClaudeHookInput {
  public static func command(data: Data, pid: Int32) throws -> AgentCommand {
    guard data.count <= 1_048_576,
      let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let run = input["session_id"] as? String, let event = input["hook_event_name"] as? String
    else {
      throw InputError("Invalid Claude hook input.")
    }
    let verb: AgentCommand.Verb
    switch event {
    case "UserPromptSubmit": verb = .begin
    case "PreToolUse": verb = .renew
    case "Stop", "StopFailure", "SessionEnd": verb = .end
    default: throw InputError("Unsupported Claude hook event.")
    }
    try AgentCommand.validate(agent: "claude", run: run)
    return AgentCommand(
      verb: verb, agent: "claude", run: run, json: false,
      pid: verb == .begin ? pid : nil, decidedByHook: true)
  }
}
