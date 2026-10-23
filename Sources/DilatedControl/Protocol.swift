import DilatedCore
import Foundation

public enum ControlAction: String, Codable, Sendable {
  case status, start, lease, runner, renew, release, stopAll, toggle
  case helperStatus, helperSetup, helperRemove
}
public struct ControlRequest: Codable, Sendable {
  public var action: ControlAction
  public var id: UUID?
  public var label: String
  public var duration: TimeInterval?
  public var until: String?
  public var displayAwake: Bool
  public var lowPowerOverride: Bool
  public var closedLid: Bool
  public init(
    action: ControlAction, id: UUID? = nil, label: String = "Command line",
    duration: TimeInterval? = nil,
    until: String? = nil, displayAwake: Bool = false, lowPowerOverride: Bool = false,
    closedLid: Bool = false
  ) {
    self.action = action
    self.id = id
    self.label = label
    self.duration = duration
    self.until = until
    self.displayAwake = displayAwake
    self.lowPowerOverride = lowPowerOverride
    self.closedLid = closedLid
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      action: try values.decode(ControlAction.self, forKey: .action),
      id: try values.decodeIfPresent(UUID.self, forKey: .id),
      label: try values.decodeIfPresent(String.self, forKey: .label) ?? "Command line",
      duration: try values.decodeIfPresent(TimeInterval.self, forKey: .duration),
      until: try values.decodeIfPresent(String.self, forKey: .until),
      displayAwake: try values.decodeIfPresent(Bool.self, forKey: .displayAwake) ?? false,
      lowPowerOverride: try values.decodeIfPresent(Bool.self, forKey: .lowPowerOverride) ?? false,
      closedLid: try values.decodeIfPresent(Bool.self, forKey: .closedLid) ?? false)
  }

}
public struct ControlResponse: Codable, Sendable {
  public var ok: Bool
  public var id: UUID?
  public var snapshot: EngineSnapshot?
  public var message: String?
  public var code: String?
  public var helper: HelperState?
  public var helperInstallation: String?
  public init(
    ok: Bool, id: UUID? = nil, snapshot: EngineSnapshot? = nil, message: String? = nil,
    code: String? = nil, helper: HelperState? = nil, helperInstallation: String? = nil
  ) {
    self.ok = ok
    self.id = id
    self.snapshot = snapshot
    self.message = message
    self.code = code
    self.helper = helper
    self.helperInstallation = helperInstallation
  }
}
public enum ControlRouter {
  public static func handle(_ request: ControlRequest, engine: inout WakeEngine, now: Date = Date())
    -> ControlResponse
  {
    do {
      guard !request.closedLid else {
        throw InputError("Closed-lid requests require the app's approved helper.")
      }
      engine.tick(now: now)
      var id: UUID?
      switch request.action {
      case .helperStatus, .helperSetup, .helperRemove:
        throw InputError("Helper management requires the Dilated app.")
      case .status: break
      case .stopAll: engine.stopAll()
      case .release:
        if let selected = request.id {
          guard engine.holds.contains(where: { $0.id == selected }) else {
            throw WakeError.holdNotFound
          }
          engine.stop(id: selected)
        } else {
          let matches = engine.holds.filter { $0.label == request.label && $0.source != .manual }
          guard !matches.isEmpty else { throw WakeError.holdNotFound }
          for hold in matches { engine.stop(id: hold.id) }
        }
      case .renew:
        guard let selected = request.id, let duration = request.duration else {
          throw WakeError.invalidDuration
        }
        try engine.renew(id: selected, duration: duration, now: now)
        id = selected
      case .toggle where !engine.holds.isEmpty: engine.stopAll()
      case .start, .lease, .runner, .toggle:
        guard request.duration == nil || request.until == nil else {
          throw WakeError.invalidDuration
        }
        let duration =
          try request.until.map { try TimeInput.until($0, now: now).timeIntervalSince(now) }
          ?? request.duration
        let source: HoldSource =
          request.action == .lease ? .lease : request.action == .runner ? .runner : .cli
        id = try engine.start(
          source: source, label: request.label, duration: duration,
          displayAwake: request.displayAwake, lowPowerOverride: request.lowPowerOverride, now: now
        ).id
      }
      return ControlResponse(ok: true, id: id, snapshot: engine.snapshot)
    } catch {
      return ControlResponse(
        ok: false, snapshot: engine.snapshot, message: error.localizedDescription,
        code: (error as? WakeError)?.rawValue ?? "invalidRequest")
    }
  }
}

public struct InputError: LocalizedError {
  public let text: String
  public init(_ text: String) { self.text = text }
  public var errorDescription: String? { text }
}

public struct CLIInput {
  public var request: ControlRequest?
  public var command: [String] = []
  public var json = false
  public var help = false

  public static func parse(_ arguments: [String]) throws -> CLIInput {
    guard let verb = arguments.first, !["--help", "-h", "help"].contains(verb) else {
      return CLIInput(help: true)
    }
    if verb == "helper" {
      let actions: [String: ControlAction] = [
        "status": .helperStatus, "setup": .helperSetup, "remove": .helperRemove,
      ]
      guard arguments.count >= 2, let action = actions[arguments[1]],
        arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--json")
      else { throw InputError("Use dilated helper status|setup|remove [--json].") }
      return CLIInput(request: .init(action: action), json: arguments.count == 3)
    }
    let actions: [String: ControlAction] = [
      "status": .status, "on": .start, "off": .stopAll,
      "hold": .lease, "release": .release, "run": .runner,
    ]
    guard let action = actions[verb] else {
      throw InputError("Unknown command: \(verb). Use dilated --help.")
    }
    var request = ControlRequest(action: action)
    var result = CLIInput()
    var seen: Set<String> = []
    var index = 1
    let allowed: Set<String> =
      switch verb {
      case "status": ["--json"]
      case "on":
        [
          "--for", "--until", "--label", "--display-awake", "--display-sleep",
          "--override-low-power", "--lid", "--json",
        ]
      case "off", "release": ["--id", "--label", "--json"]
      case "hold":
        [
          "--id", "--ttl", "--label", "--display-awake", "--display-sleep", "--override-low-power",
          "--lid", "--json",
        ]
      case "run":
        [
          "--label", "--display-awake", "--display-sleep", "--override-low-power", "--lid",
          "--json",
        ]
      default: []
      }
    while index < arguments.count {
      let flag = arguments[index]
      if flag == "--", verb == "run" {
        result.command = Array(arguments.dropFirst(index + 1))
        break
      }
      guard allowed.contains(flag), seen.insert(flag).inserted else {
        throw InputError("Unknown or repeated option: \(flag)")
      }
      index += 1
      switch flag {
      case "--json": result.json = true
      case "--display-awake": request.displayAwake = true
      case "--display-sleep": request.displayAwake = false
      case "--override-low-power": request.lowPowerOverride = true
      case "--lid": request.closedLid = true
      default:
        guard index < arguments.count else { throw InputError("Missing value for \(flag).") }
        let value = arguments[index]
        index += 1
        switch flag {
        case "--for", "--ttl": request.duration = try TimeInput.duration(value)
        case "--until":
          _ = try TimeInput.until(value)
          request.until = value
        case "--label":
          guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError("Label can't be empty.")
          }
          request.label = value
        case "--id":
          guard let id = UUID(uuidString: value) else {
            throw InputError("Hold ID must be a UUID.")
          }
          request.id = id
        default: break
        }
      }
    }
    guard request.duration == nil || request.until == nil,
      !(seen.contains("--display-awake") && seen.contains("--display-sleep"))
    else {
      throw InputError("Choose one duration and one display option.")
    }
    if verb == "hold" {
      guard request.duration != nil else {
        throw InputError("hold requires --ttl, for example --ttl 10m.")
      }
      if request.id != nil { request.action = .renew }
      if request.id != nil && request.closedLid {
        throw InputError("Renewals can't enable closed-lid. Start a new hold or use the menu.")
      }
    }
    if verb == "off", request.id != nil || seen.contains("--label") { request.action = .release }
    if verb == "release", request.id == nil && !seen.contains("--label") {
      throw InputError("release requires --id or --label.")
    }
    if verb == "run", result.command.isEmpty {
      throw InputError("Use dilated run -- command arguments.")
    }
    result.request = request
    return result
  }
}

public enum URLInput {
  public static func parse(_ url: URL) throws -> ControlRequest {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "dilated", let host = components.host,
      ["awake", "stop", "toggle"].contains(host),
      components.path.isEmpty, components.fragment == nil, components.user == nil,
      components.port == nil
    else {
      throw InputError("Use dilated://awake, dilated://stop or dilated://toggle.")
    }
    let items = components.queryItems ?? []
    var values: [String: String] = [:]
    for item in items {
      guard ["for", "until", "display", "lid"].contains(item.name), values[item.name] == nil,
        let value = item.value
      else {
        throw InputError("Unsupported or repeated URL option.")
      }
      values[item.name] = value
    }
    guard values["for"] == nil || values["until"] == nil,
      host != "stop" || values.isEmpty
    else { throw InputError("Conflicting URL options.") }
    if let display = values["display"], !["allow", "prevent"].contains(display) {
      throw InputError("display must be allow or prevent.")
    }
    if let lid = values["lid"], !["open", "closed"].contains(lid) {
      throw InputError("lid must be open or closed.")
    }
    let duration = try values["for"].map(TimeInput.duration)
    if let until = values["until"] { _ = try TimeInput.until(until) }
    return ControlRequest(
      action: host == "stop" ? .stopAll : host == "toggle" ? .toggle : .start,
      label: "Automation link", duration: duration, until: values["until"],
      displayAwake: values["display"] == "prevent", closedLid: values["lid"] == "closed")
  }
}
