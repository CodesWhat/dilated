import DilatedControl
import Foundation

enum ScriptOperation: String, CaseIterable, Sendable {
  case isActive = "cAct"
  case start = "cmOn"
  case stop = "cOff"
  case remaining = "STRm"
  case displayAllowed = "DSOK"
  case allowDisplaySleep = "AWDS"
  case preventDisplaySleep = "PTDS"
  case closedLidEnabled = "CDMK"
  case enableClosedLid = "ECDM"
  case disableClosedLid = "DCDM"
  case isTrigger = "SisT"
  case triggersEnabled = "TrEn"
  case enableTriggers = "EnTr"
  case disableTriggers = "DsTr"
  var eventID: UInt32 { rawValue.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}
enum ScriptValue: Equatable, Sendable {
  case none
  case boolean(Bool)
  case integer(Int)
}

@MainActor public final class AutomationService {
  public static let shared = AutomationService()
  private weak var model: AppModel?
  private var isUnavailable = false
  private let readinessTimeout: Duration

  public init(readinessTimeout: Duration = .seconds(5)) {
    self.readinessTimeout = readinessTimeout
  }
  public func bind(_ model: AppModel) {
    self.model = model
    isUnavailable = false
  }
  public func unavailable() {
    model = nil
    isUnavailable = true
  }
  private func ready() async throws -> AppModel {
    let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
    while true {
      try Task.checkCancellation()
      if isUnavailable { throw InputError("Dilated is unavailable or quitting.") }
      if let model { return model }
      guard ContinuousClock.now < deadline else {
        throw InputError("Dilated hasn't finished starting. Try again after it opens.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  @discardableResult public func start(
    duration: TimeInterval? = nil, displayAwake: Bool? = nil
  ) async throws -> UUID {
    let model = try await ready()
    let response = await model.control(
      .init(
        action: .start, label: "Shortcut", duration: duration,
        displayAwake: displayAwake ?? !model.settings.allowDisplaySleep), origin: .shortcut)
    try requireSuccess(response)
    guard let id = response.id else { throw InputError("Dilated didn't return a hold ID.") }
    return id
  }
  @discardableResult public func startScript(_ options: ScriptStartOptions) async throws -> UUID {
    try await ready().startScript(options)
  }
  public func stop() async throws {
    let model = try await ready()
    try requireSuccess(await model.control(.init(action: .stopAll)))
  }
  public func status() async throws -> String {
    let model = try await ready()
    let response = await model.control(.init(action: .status))
    try requireSuccess(response)
    guard let snapshot = response.snapshot else { throw InputError("Awake state is unavailable.") }
    let holds = snapshot.holds.map { hold in
      let end = hold.expiry.map { ISO8601DateFormatter().string(from: $0) } ?? "indefinitely"
      return "\(hold.id.uuidString): \(hold.label), \(hold.source.rawValue), \(end)"
    }
    let changing = model.closedLid.busy || model.closedLid.pendingEnable
    let helper =
      changing
      ? "changing (unconfirmed)"
      : response.helper.map { state in
        state.enabled ? "on" : state.readback.confirmedDisabled ? "off" : "unknown"
      } ?? "unknown"
    return
      ([
        snapshot.holds.isEmpty ? "Sleeping normally" : "Keeping awake",
        "Automation: \(snapshot.automationPaused ? "paused" : "running")",
        "Closed-lid requested: \(snapshot.holds.contains { $0.closedLid == true } ? "yes" : "no")",
        "Helper state: \(helper)",
      ] + holds).joined(separator: "\n")
  }
  public func setClosedLid(id: UUID, enabled: Bool) async throws {
    try await ready().setAutomationClosedLid(id: id, enabled: enabled)
  }
  public func setTriggersEnabled(_ enabled: Bool) async throws {
    try await ready().setTriggersEnabled(enabled)
  }
  func script(_ operation: ScriptOperation, options: ScriptStartOptions? = nil) async throws
    -> ScriptValue
  {
    let model = try await ready()
    switch operation {
    case .start:
      _ = try await model.startScript(options ?? .init(usesDefaultDuration: true))
      return .none
    case .stop:
      try await stop()
      return .none
    case .allowDisplaySleep, .preventDisplaySleep:
      try model.setScriptDisplayAwake(operation == .preventDisplaySleep)
      return .none
    case .enableTriggers, .disableTriggers:
      try model.setTriggersEnabled(operation == .enableTriggers)
      return .none
    case .enableClosedLid, .disableClosedLid:
      let id = try model.scriptClosedLidTarget()
      try await model.setAutomationClosedLid(id: id, enabled: operation == .enableClosedLid)
      return .none
    default: break
    }
    try requireSuccess(await model.control(.init(action: .status)))
    let holds = model.engine.holds
    switch operation {
    case .isActive: return .boolean(!holds.isEmpty)
    case .displayAllowed:
      return .boolean(
        holds.isEmpty ? model.settings.allowDisplaySleep : !model.engine.desiredState.displayAwake)
    case .isTrigger: return .boolean(holds.contains { $0.source == .trigger })
    case .triggersEnabled: return .boolean(model.settings.triggersEnabled)
    case .closedLidEnabled:
      guard !model.closedLid.busy, !model.closedLid.pendingEnable else {
        throw InputError("Closed-lid is still changing. Wait for confirmation before querying it.")
      }
      guard let helper = model.closedLid.state else {
        throw InputError("Closed-lid helper state is unknown.")
      }
      guard helper.enabled || helper.readback.confirmedDisabled else {
        throw InputError("Closed-lid helper state is unknown.")
      }
      return .boolean(helper.enabled)
    case .remaining:
      if holds.isEmpty { return .integer(-3) }
      if holds.contains(where: { $0.expiry == nil && $0.source != .trigger }) { return .integer(0) }
      if holds.contains(where: { $0.source == .trigger }) { return .integer(-1) }
      let seconds = holds.compactMap(\.expiry).map { $0.timeIntervalSince(model.now) }.max() ?? 0
      return .integer(Int(ceil(max(0, min(seconds, 315_576_000)))))
    default: throw InputError("Unsupported AppleScript command.")
    }
  }
  private func requireSuccess(_ response: ControlResponse) throws {
    guard response.ok else {
      throw InputError(response.message ?? "Dilated couldn't finish the command.")
    }
  }
}
