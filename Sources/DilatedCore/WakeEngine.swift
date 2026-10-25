import Foundation

public enum HoldSource: String, Codable, Sendable {
  case manual, cli, lease, runner, url, trigger, shortcut, appleScript
}
public struct Hold: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var source: HoldSource
  public var label: String
  public var createdAt: Date
  public var expiry: Date?
  public var displayAwake: Bool
  public var lowPowerOverride: Bool
  public var batteryOverride: Bool?
  public var closedLid: Bool?
}
public struct PowerState: Codable, Equatable, Sendable {
  public var onBattery: Bool
  public var batteryPercent: Int?
  public var lowPowerMode: Bool
  public init(onBattery: Bool = false, batteryPercent: Int? = nil, lowPowerMode: Bool = false) {
    self.onBattery = onBattery
    self.batteryPercent = batteryPercent
    self.lowPowerMode = lowPowerMode
  }
}
public struct EngineSnapshot: Codable, Sendable {
  public var holds: [Hold]
  public var automationPaused: Bool
  public init(holds: [Hold] = [], automationPaused: Bool = false) {
    self.holds = holds
    self.automationPaused = automationPaused
  }
}
public enum WakeError: String, Error, Codable, Sendable, LocalizedError {
  case automationPaused, holdNotFound, notRenewable, lowPowerMode, lowBattery, invalidDuration,
    notTimed
  public var errorDescription: String? {
    switch self {
    case .automationPaused: "Automation is paused. Choose Resume automation in Dilated."
    case .holdNotFound: "That hold has ended or doesn't exist."
    case .notRenewable: "Only agent leases and command holds can be renewed."
    case .lowPowerMode: "Stopped: Low Power Mode. Use an explicit override to continue."
    case .lowBattery: "Stopped: battery is below the configured floor."
    case .invalidDuration: "Duration must be a positive, finite amount of time."
    case .notTimed: "An indefinite hold can't be extended."
    }
  }
}
public struct DesiredState: Equatable, Sendable {
  public var systemAwake = false
  public var displayAwake = false
  public var closedLid = false
}
public struct UserReturnRestoration: Equatable, Sendable {
  public var holds: [Hold]
  public var wasPaused: Bool
}
public struct WakeEngine: Sendable {
  public private(set) var holds: [Hold] = []
  private var historyEvents: [HoldHistoryEvent] = []
  public private(set) var automationPaused = false
  public private(set) var userReturnRestoration: UserReturnRestoration?
  public private(set) var attention: String?
  public private(set) var power = PowerState()
  public var batteryFloor: Int?
  public var batteryFloorIgnoresAC: Bool
  public var desiredState: DesiredState {
    DesiredState(
      systemAwake: !holds.isEmpty, displayAwake: holds.contains { $0.displayAwake },
      closedLid: holds.contains { $0.closedLid == true })
  }
  public var snapshot: EngineSnapshot {
    EngineSnapshot(holds: holds, automationPaused: automationPaused)
  }

  public init(
    snapshot: EngineSnapshot = EngineSnapshot(), now: Date = Date(),
    power: PowerState = PowerState(), batteryFloor: Int? = nil, batteryFloorIgnoresAC: Bool = true
  ) {
    self.batteryFloor = batteryFloor
    self.batteryFloorIgnoresAC = batteryFloorIgnoresAC
    self.power = power
    automationPaused = snapshot.automationPaused
    holds = snapshot.holds.filter {
      guard let expiry = $0.expiry, expiry > now else { return false }
      return $0.source != .lease && $0.source != .runner && $0.source != .trigger
        && (!automationPaused || $0.source == .manual)
    }.map {
      var hold = $0
      hold.closedLid = nil
      return hold
    }
    for hold in holds { recordHistory(hold: hold, at: now) }
    updatePower(power, now: now)
  }

  @discardableResult public mutating func start(
    source: HoldSource, label: String, duration: TimeInterval? = nil,
    displayAwake: Bool = false, lowPowerOverride: Bool = false, batteryOverride: Bool = false,
    closedLid: Bool = false, now: Date = Date()
  ) throws -> Hold {
    tick(now: now)
    if automationPaused && source != .manual { throw WakeError.automationPaused }
    if let duration { try Self.validate(duration) }
    if (source == .lease || source == .runner) && duration == nil {
      throw WakeError.invalidDuration
    }
    try checkSafety(lowPowerOverride: lowPowerOverride, batteryOverride: batteryOverride)
    let hold = Hold(
      id: UUID(), source: source, label: String(label.prefix(200)), createdAt: now,
      expiry: duration.map { now.addingTimeInterval($0) }, displayAwake: displayAwake,
      lowPowerOverride: lowPowerOverride, batteryOverride: batteryOverride ? true : nil,
      closedLid: closedLid ? true : nil)
    holds.append(hold)
    recordHistory(hold: hold, at: now)
    attention = nil
    return hold
  }

  public mutating func takeHistoryEvents() -> [HoldHistoryEvent] {
    let events = historyEvents
    historyEvents.removeAll(keepingCapacity: true)
    return events
  }
  private mutating func recordHistory(
    hold: Hold, at: Date, reason: HoldEndReason? = nil, kind: HoldEventKind? = nil
  ) {
    historyEvents.append(.init(hold: hold, at: at, endReason: reason, kind: kind))
    if historyEvents.count > 1024 { historyEvents.removeFirst(historyEvents.count - 1024) }
  }
  public mutating func stop(id: UUID, reason: HoldEndReason = .stopped, now: Date = Date()) {
    userReturnRestoration?.holds.removeAll { $0.id == id }
    guard let hold = holds.first(where: { $0.id == id }) else { return }
    recordHistory(hold: hold, at: now, reason: reason)
    holds.removeAll { $0.id == id }
  }
  public mutating func stopAll(reason: HoldEndReason = .stopped, now: Date = Date()) {
    for hold in holds { recordHistory(hold: hold, at: now, reason: reason) }
    holds.removeAll()
    automationPaused = true
    attention = nil
    userReturnRestoration = nil
  }
  public mutating func suspendForUserSwitch(
    capture: Bool, excluding: Set<UUID> = [], now: Date = Date()
  ) {
    let record =
      capture
      ? UserReturnRestoration(
        holds: holds.filter { $0.source != .trigger && !excluding.contains($0.id) },
        wasPaused: automationPaused)
      : nil
    stopAll(reason: .userSwitch, now: now)
    userReturnRestoration = record
  }
  public mutating func resumeAfterUserReturn(now: Date = Date()) -> UserReturnRestoration? {
    guard let record = userReturnRestoration else { return nil }
    userReturnRestoration = nil
    if !record.wasPaused { resumeAutomation() }
    restore(holds: record.holds, now: now)
    return record
  }
  public mutating func discardUserReturnRestoration() { userReturnRestoration = nil }
  public mutating func resumeAutomation() {
    automationPaused = false
    attention = nil
    userReturnRestoration = nil
  }
  public mutating func restore(holds restored: [Hold], now: Date = Date()) {
    tick(now: now)
    var didRestore = false
    for var hold in restored where hold.source != .trigger {
      if let expiry = hold.expiry, expiry <= now { continue }
      if holds.contains(where: { $0.id == hold.id }) { continue }
      hold.closedLid = nil
      holds.append(hold)
      recordHistory(hold: hold, at: now)
      didRestore = true
    }
    if didRestore { attention = nil }
    updatePower(power, now: now)
  }
  public mutating func quit(reason: HoldEndReason = .quit, now: Date = Date()) {
    for hold in holds { recordHistory(hold: hold, at: now, reason: reason) }
    holds.removeAll()
    userReturnRestoration = nil
  }
  public mutating func tick(now: Date = Date()) {
    for hold in holds where hold.expiry.map({ $0 <= now }) == true {
      recordHistory(hold: hold, at: hold.expiry!, reason: .expired)
    }
    holds.removeAll { $0.expiry.map { $0 <= now } ?? false }
  }
  public mutating func updatePower(_ power: PowerState, now: Date = Date()) {
    self.power = power
    tick(now: now)
    let before = holds.count
    let lowBattery = batteryBlocked
    for hold in holds {
      if lowBattery && hold.batteryOverride != true {
        recordHistory(hold: hold, at: now, reason: .lowBattery)
      } else if power.lowPowerMode && !hold.lowPowerOverride {
        recordHistory(hold: hold, at: now, reason: .lowPowerMode)
      }
    }
    holds.removeAll { hold in
      (power.lowPowerMode && !hold.lowPowerOverride) || (lowBattery && hold.batteryOverride != true)
    }
    if holds.count != before {
      attention =
        batteryBlocked
        ? "Stopped: battery \(power.batteryPercent ?? 0)%."
        : WakeError.lowPowerMode.localizedDescription
    }
  }
  public mutating func renew(id: UUID, duration: TimeInterval, now: Date = Date()) throws {
    tick(now: now)
    if automationPaused { throw WakeError.automationPaused }
    try Self.validate(duration)
    guard let index = holds.firstIndex(where: { $0.id == id }) else { throw WakeError.holdNotFound }
    guard holds[index].source == .lease || holds[index].source == .runner else {
      throw WakeError.notRenewable
    }
    try checkSafety(
      lowPowerOverride: holds[index].lowPowerOverride,
      batteryOverride: holds[index].batteryOverride == true)
    holds[index].expiry = now.addingTimeInterval(duration)
  }
  public mutating func extend(id: UUID, by duration: TimeInterval, now: Date = Date()) throws {
    tick(now: now)
    try Self.validate(duration)
    guard let index = holds.firstIndex(where: { $0.id == id }) else { throw WakeError.holdNotFound }
    guard let expiry = holds[index].expiry else { throw WakeError.notTimed }
    holds[index].expiry = expiry.addingTimeInterval(duration)
    recordHistory(hold: holds[index], at: now, kind: .extended)
  }
  public mutating func setDisplayAwake(id: UUID, enabled: Bool) {
    guard let index = holds.firstIndex(where: { $0.id == id }) else { return }
    holds[index].displayAwake = enabled
  }
  public mutating func setClosedLid(id: UUID, enabled: Bool) {
    guard let index = holds.firstIndex(where: { $0.id == id }) else { return }
    holds[index].closedLid = enabled ? true : nil
  }
  public mutating func clearClosedLidRequests() {
    for index in holds.indices { holds[index].closedLid = nil }
  }
  private var batteryBlocked: Bool {
    guard power.onBattery || !batteryFloorIgnoresAC,
      let percent = power.batteryPercent, let floor = batteryFloor
    else {
      return false
    }
    return percent < floor
  }
  private func checkSafety(lowPowerOverride: Bool, batteryOverride: Bool = false) throws {
    if batteryBlocked && !batteryOverride { throw WakeError.lowBattery }
    if power.lowPowerMode && !lowPowerOverride { throw WakeError.lowPowerMode }
  }
  private static func validate(_ duration: TimeInterval) throws {
    guard duration.isFinite && duration > 0 && duration <= 315_576_000 else {
      throw WakeError.invalidDuration
    }
  }
}
