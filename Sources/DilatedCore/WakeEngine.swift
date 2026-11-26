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
/// A hold the user stopped, kept so a late renew can be told apart from a lost hold.
public struct ReleasedHold: Codable, Equatable, Sendable {
  public var id: UUID
  public var at: Date
  public init(id: UUID, at: Date) {
    self.id = id
    self.at = at
  }
}
public struct EngineSnapshot: Codable, Sendable {
  public var holds: [Hold]
  public var automationPaused: Bool
  /// Recently released holds (last 64, under a day old). Optional on the wire, so older files and
  /// readers that don't know the key keep working.
  public var released: [ReleasedHold]
  public init(
    holds: [Hold] = [], automationPaused: Bool = false, released: [ReleasedHold] = []
  ) {
    self.holds = holds
    self.automationPaused = automationPaused
    self.released = released
  }
  private enum CodingKeys: String, CodingKey { case holds, automationPaused, released }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    holds = try c.decode([Hold].self, forKey: .holds)
    automationPaused = try c.decode(Bool.self, forKey: .automationPaused)
    released = try c.decodeIfPresent([ReleasedHold].self, forKey: .released) ?? []
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(holds, forKey: .holds)
    try c.encode(automationPaused, forKey: .automationPaused)
    if !released.isEmpty { try c.encode(released, forKey: .released) }
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
  /// Recently released holds, newest last. Carried in the snapshot so an app restart still reads a
  /// released hold as released, not lost. Capped by count and age.
  private var releasedHolds: [ReleasedHold] = []
  static let releasedLimit = 64
  public static let releasedMaxAge: TimeInterval = 24 * 3600
  public private(set) var automationPaused = false
  public private(set) var leavingPending = false
  private var leavingIdleSince: TimeInterval?
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
    EngineSnapshot(
      holds: holds, automationPaused: automationPaused,
      released: releasedHolds)
  }
  private static func prunedReleased(_ list: [ReleasedHold], now: Date) -> [ReleasedHold] {
    Array(list.filter { now.timeIntervalSince($0.at) < releasedMaxAge }.suffix(releasedLimit))
  }

  public init(
    snapshot: EngineSnapshot = EngineSnapshot(), now: Date = Date(),
    power: PowerState = PowerState(), batteryFloor: Int? = nil, batteryFloorIgnoresAC: Bool = true
  ) {
    self.batteryFloor = batteryFloor
    self.batteryFloorIgnoresAC = batteryFloorIgnoresAC
    self.power = power
    automationPaused = snapshot.automationPaused
    releasedHolds = Self.prunedReleased(snapshot.released, now: now)
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
    cancelLeaving()
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
    // A hold suspended for a user switch is still the user's to release: remember the release so
    // a runner that refreshes after the user returns doesn't register a new hold.
    let suspended = userReturnRestoration?.holds.contains { $0.id == id } == true
    userReturnRestoration?.holds.removeAll { $0.id == id }
    let hold = holds.first(where: { $0.id == id })
    guard hold != nil || suspended else { return }
    if reason == .stopped {
      releasedHolds.removeAll { $0.id == id }
      releasedHolds.append(ReleasedHold(id: id, at: now))
      releasedHolds = Self.prunedReleased(releasedHolds, now: now)
    }
    guard let hold else { return }
    recordHistory(hold: hold, at: now, reason: reason)
    holds.removeAll { $0.id == id }
  }
  /// True when this engine ended the hold because the user stopped it (not expiry or a restart).
  public func wasReleased(id: UUID, now: Date = Date()) -> Bool {
    releasedHolds.contains { $0.id == id && now.timeIntervalSince($0.at) < Self.releasedMaxAge }
  }
  public func releasableHold(id: UUID) -> Bool {
    holds.contains { $0.id == id } || userReturnRestoration?.holds.contains { $0.id == id } == true
  }
  public func releasableHolds(label: String) -> [Hold] {
    var seen = Set<UUID>()
    return (holds + (userReturnRestoration?.holds ?? [])).filter {
      $0.label == label && $0.source != .manual && seen.insert($0.id).inserted
    }
  }
  public mutating func stopAll(reason: HoldEndReason = .stopped, now: Date = Date()) {
    cancelLeaving()
    for hold in holds { recordHistory(hold: hold, at: now, reason: reason) }
    holds.removeAll()
    automationPaused = true
    attention = nil
    userReturnRestoration = nil
  }
  public mutating func suspendForUserSwitch(
    capture: Bool, excluding: Set<UUID> = [], now: Date = Date()
  ) {
    let existing = userReturnRestoration
    var record: UserReturnRestoration?
    if capture {
      let captured = holds.filter { $0.source != .trigger && !excluding.contains($0.id) }
      if let existing {
        let known = Set(existing.holds.map(\.id))
        let merged = existing.holds + captured.filter { !known.contains($0.id) }
        record = UserReturnRestoration(holds: merged, wasPaused: existing.wasPaused)
      } else {
        record =
          captured.isEmpty && automationPaused
          ? nil : UserReturnRestoration(holds: captured, wasPaused: automationPaused)
      }
    }
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
    let activeScripts = holds.filter { $0.source == .appleScript }
    for var hold in restored where hold.source != .trigger {
      if let expiry = hold.expiry, expiry <= now { continue }
      if holds.contains(where: { $0.id == hold.id }) { continue }
      if hold.source == .appleScript,
        activeScripts.contains(where: { $0.label == hold.label && Self.covers($0, hold) })
      {
        continue
      }
      hold.closedLid = nil
      holds.append(hold)
      recordHistory(hold: hold, at: now)
      didRestore = true
    }
    if didRestore {
      cancelLeaving()
      attention = nil
    }
    updatePower(power, now: now)
  }
  private static func covers(_ active: Hold, _ restored: Hold) -> Bool {
    let expiryCovered: Bool
    if let activeExpiry = active.expiry {
      expiryCovered = restored.expiry.map { activeExpiry >= $0 } ?? false
    } else {
      expiryCovered = true
    }
    return expiryCovered
      && (active.displayAwake || !restored.displayAwake)
      && (active.lowPowerOverride || !restored.lowPowerOverride)
      && (active.batteryOverride == true || restored.batteryOverride != true)
  }
  public mutating func quit(reason: HoldEndReason = .quit, now: Date = Date()) {
    cancelLeaving()
    for hold in holds { recordHistory(hold: hold, at: now, reason: reason) }
    holds.removeAll()
    userReturnRestoration = nil
  }
  public mutating func leaveWhenIdle() {
    leavingPending = true
    leavingIdleSince = nil
  }
  public mutating func cancelLeaving() {
    leavingPending = false
    leavingIdleSince = nil
  }
  /// The 5s grace is measured on `uptime` (a monotonic clock) so a wall-clock change can't shorten or lengthen it.
  public mutating func leavingSleepReady(
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    guard leavingPending else { return false }
    guard holds.isEmpty else {
      leavingIdleSince = nil
      return false
    }
    guard let leavingIdleSince else {
      self.leavingIdleSince = uptime
      return false
    }
    return uptime - leavingIdleSince >= 5
  }
  public mutating func takeLeavingSleepRequest(
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    guard leavingSleepReady(uptime: uptime) else { return false }
    cancelLeaving()
    return true
  }
  public mutating func tick(now: Date = Date()) {
    for hold in holds where hold.expiry.map({ $0 <= now }) == true {
      recordHistory(hold: hold, at: hold.expiry!, reason: .expired)
    }
    holds.removeAll { $0.expiry.map { $0 <= now } ?? false }
  }
  @discardableResult
  public mutating func updatePower(_ power: PowerState, now: Date = Date()) -> Set<UUID> {
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
    let unsafe = Set(
      holds.filter { hold in
        (power.lowPowerMode && !hold.lowPowerOverride)
          || (lowBattery && hold.batteryOverride != true)
      }.map(\.id))
    holds.removeAll { unsafe.contains($0.id) }
    if holds.count != before {
      attention =
        batteryBlocked
        ? "Stopped: battery \(power.batteryPercent ?? 0)%."
        : WakeError.lowPowerMode.localizedDescription
    }
    return unsafe
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
