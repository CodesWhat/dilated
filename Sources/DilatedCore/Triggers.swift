import Darwin
import Foundation

public struct WeeklySchedule: Codable, Equatable, Sendable {
  public var weekdays: Set<Int>
  public var startMinute: Int
  public var endMinute: Int
  public init(weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
    self.weekdays = weekdays
    self.startMinute = startMinute
    self.endMinute = endMinute
  }
  public var isValid: Bool {
    !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
      && (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
  }
  public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
    guard isValid else { return false }
    let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
    guard let day = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
      return false
    }
    let time = hour * 60 + minute
    if startMinute == endMinute { return weekdays.contains(day) }
    if startMinute < endMinute {
      return weekdays.contains(day) && time >= startMinute && time < endMinute
    }
    let previous = day == 1 ? 7 : day - 1
    return (weekdays.contains(day) && time >= startMinute)
      || (weekdays.contains(previous) && time < endMinute)
  }
  public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
    guard isValid else { return nil }
    var candidates: [Date] = []
    for day in weekdays {
      let endDay = startMinute > endMinute ? day % 7 + 1 : day
      let boundaries =
        startMinute == endMinute
        ? [(day, 0), (day % 7 + 1, 0)] : [(day, startMinute), (endDay, endMinute)]
      for (weekday, minute) in boundaries {
        for repeated: Calendar.RepeatedTimePolicy in [.first, .last] {
          if let next = calendar.nextDate(
            after: date,
            matching: DateComponents(
              hour: minute / 60, minute: minute % 60, second: 0, weekday: weekday),
            matchingPolicy: .nextTime, repeatedTimePolicy: repeated)
          {
            candidates.append(next)
          }
        }
      }
    }
    return candidates.min()
  }
}

public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
  public var pid: Int32
  public var startedAtMicroseconds: UInt64
  public init(pid: Int32, startedAtMicroseconds: UInt64) {
    self.pid = pid
    self.startedAtMicroseconds = startedAtMicroseconds
  }
}

public enum TriggerCriterion: Codable, Equatable, Sendable {
  case application(bundleID: String, frontmostOnly: Bool)
  case process(name: String)
  case processInstance(ProcessIdentity)
  case schedule(WeeklySchedule)
  case power(onBattery: Bool)
  case battery(minimum: Int, maximum: Int)
  case displays(minimum: Int, maximum: Int, externalOnly: Bool)
  case mirrored(Bool)
  case network(address: String)
  case gateway(address: String)
  case dns(address: String)
  case volume(path: String)
  case cpu(percent: Int, atLeast: Bool)
  case idle(seconds: TimeInterval, atLeast: Bool)
}

public struct TriggerInputs: Sendable {
  public var applications: Set<String> = []
  public var frontmostApplication: String?
  public var processNames: Set<String> = []
  public var processInstances: Set<ProcessIdentity> = []
  public var power = PowerState()
  public var displayCount: Int?
  public var externalDisplayCount: Int?
  public var mirroredDisplays: Bool?
  public var addresses: Set<String> = []
  public var gateways: Set<String> = []
  public var dnsServers: Set<String> = []
  public var mountedVolumes: Set<String>?
  public var cpuPercent: Double?
  public var idleSeconds: TimeInterval?
  public init() {}
}

public struct TriggerRule: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var enabled = true
  public var criteria: [TriggerCriterion]
  public var displayAwake = false
  public var lowPowerOverride = false
  public var dwellSeconds: TimeInterval = 0
  public var graceSeconds: TimeInterval = 0
  public var pausedUntil: Date?
  public init(name: String, criteria: [TriggerCriterion]) {
    self.name = name
    self.criteria = criteria
  }
  public var validationMessage: String? {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 {
      return "Use a name between 1 and 100 characters."
    }
    if criteria.isEmpty || criteria.count > 12 { return "Choose at least one condition, up to 12." }
    if !dwellSeconds.isFinite || !graceSeconds.isFinite
      || !(0...3600).contains(dwellSeconds) || !(0...3600).contains(graceSeconds)
    {
      return "Dwell and grace must be between 0 and 3600 seconds."
    }
    if criteria.contains(where: { !$0.isValid }) { return "Check the condition values." }
    return nil
  }
  public func matches(_ input: TriggerInputs, now: Date, calendar: Calendar = .current) -> Bool {
    guard validationMessage == nil else { return false }
    return criteria.allSatisfy { criterion in
      switch criterion {
      case .application(let bundleID, let frontmostOnly):
        return input.applications.contains(bundleID)
          && (!frontmostOnly || input.frontmostApplication == bundleID)
      case .process(let name): return input.processNames.contains(name)
      case .processInstance(let identity): return input.processInstances.contains(identity)
      case .mirrored(let mirrored): return input.mirroredDisplays == mirrored
      case .schedule(let schedule): return schedule.contains(now, calendar: calendar)
      case .power(let onBattery): return input.power.onBattery == onBattery
      case .battery(let minimum, let maximum):
        return input.power.batteryPercent.map { (minimum...maximum).contains($0) } ?? false
      case .displays(let minimum, let maximum, let externalOnly):
        guard let count = externalOnly ? input.externalDisplayCount : input.displayCount else {
          return false
        }
        return (minimum...maximum).contains(count)
      case .network(let address):
        return input.addresses.contains { AddressRange(address)?.contains($0) == true }
      case .gateway(let address):
        return input.gateways.contains { AddressRange(address)?.contains($0) == true }
      case .dns(let address):
        return input.dnsServers.contains { AddressRange(address)?.contains($0) == true }
      case .volume(let path):
        return input.mountedVolumes?.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
          == true
      case .cpu(let percent, let atLeast):
        guard let value = input.cpuPercent, value.isFinite, (0...100).contains(value) else {
          return false
        }
        return atLeast ? value >= Double(percent) : value <= Double(percent)
      case .idle(let seconds, let atLeast):
        guard let value = input.idleSeconds, value.isFinite, (0...315_576_000).contains(value)
        else { return false }
        return atLeast ? value >= seconds : value <= seconds
      }
    }
  }
}

extension TriggerCriterion {
  public var isValid: Bool {
    switch self {
    case .application(let bundleID, _): return !bundleID.isEmpty && bundleID.count <= 255
    case .process(let name): return !name.isEmpty && name.count <= 1024
    case .processInstance(let identity):
      return identity.pid > 0 && identity.startedAtMicroseconds > 0
    case .mirrored: return true
    case .schedule(let schedule): return schedule.isValid
    case .power: return true
    case .battery(let minimum, let maximum):
      return minimum >= 0 && maximum <= 100 && minimum <= maximum
    case .displays(let minimum, let maximum, _):
      return minimum >= 0 && maximum <= 32 && minimum <= maximum
    case .network(let address), .gateway(let address), .dns(let address):
      return AddressRange(address) != nil
    case .volume(let path): return path.hasPrefix("/") && path.count <= 1024 && !path.contains("\0")
    case .cpu(let percent, _): return (0...100).contains(percent)
    case .idle(let seconds, _): return seconds.isFinite && (0...315_576_000).contains(seconds)
    }
  }
}

private struct AddressRange {
  let bytes: [UInt8]
  let prefix: Int
  init?(_ text: String) {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let bytes = Self.parse(String(parts[0])) else {
      return nil
    }
    let prefix = parts.count == 1 ? bytes.count * 8 : Int(parts[1]) ?? -1
    guard (0...bytes.count * 8).contains(prefix) else { return nil }
    self.bytes = bytes
    self.prefix = prefix
  }
  func contains(_ address: String) -> Bool {
    guard let candidate = Self.parse(address), bytes.count == candidate.count else { return false }
    for index in bytes.indices {
      let bits = min(8, max(0, prefix - index * 8))
      let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
      if bytes[index] & mask != candidate[index] & mask { return false }
    }
    return true
  }
  private static func parse(_ address: String) -> [UInt8]? {
    let family = address.contains(":") ? AF_INET6 : AF_INET
    var bytes = [UInt8](repeating: 0, count: family == AF_INET6 ? 16 : 4)
    guard address.withCString({ inet_pton(family, $0, &bytes) }) == 1 else { return nil }
    return bytes
  }
}

public struct TriggerEvaluator: Sendable {
  private struct Runtime: Sendable {
    var rule: TriggerRule
    var holdID: UUID?
    var matchedSince: TimeInterval?
    var missingSince: TimeInterval?
    var suppressed = false
  }
  private var runtime: [UUID: Runtime] = [:]
  public private(set) var statuses: [UUID: String] = [:]
  public init() {}
  public func nextEvaluation(
    now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Date? {
    runtime.values.compactMap { state -> Date? in
      let deadline: TimeInterval?
      if state.holdID == nil, !state.suppressed, let began = state.matchedSince {
        deadline = began + state.rule.dwellSeconds
      } else if state.holdID != nil, let began = state.missingSince {
        deadline = began + state.rule.graceSeconds
      } else {
        deadline = nil
      }
      guard let deadline, deadline > uptime else { return nil }
      return now.addingTimeInterval(deadline - uptime)
    }.min()
  }
  public mutating func resume(id: UUID, engine: inout WakeEngine) {
    if let holdID = runtime.removeValue(forKey: id)?.holdID {
      engine.stop(id: holdID, reason: .reconfigured)
    }
  }
  public mutating func reconcile(
    rules: [TriggerRule], inputs: TriggerInputs, engine: inout WakeEngine, now: Date = Date(),
    uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    let ids = Set(rules.map(\.id))
    for id in runtime.keys.filter({ !ids.contains($0) }) {
      if let holdID = runtime.removeValue(forKey: id)?.holdID {
        engine.stop(id: holdID, reason: .reconfigured, now: now)
      }
    }
    statuses = [:]
    for rule in rules {
      var state = runtime[rule.id] ?? Runtime(rule: rule)
      if state.rule != rule {
        if let id = state.holdID { engine.stop(id: id, reason: .reconfigured, now: now) }
        state = Runtime(rule: rule)
      }
      defer { runtime[rule.id] = state }
      let unavailable =
        !rule.enabled || engine.automationPaused || (rule.pausedUntil.map { $0 > now } ?? false)
      if unavailable || rule.validationMessage != nil {
        if let id = state.holdID { engine.stop(id: id, reason: .reconfigured, now: now) }
        state = Runtime(rule: rule)
        statuses[rule.id] = rule.validationMessage ?? (!rule.enabled ? "Off" : "Paused")
        continue
      }
      let matches = rule.matches(inputs, now: now)
      if !matches {
        state.matchedSince = nil
        state.suppressed = false
        if state.missingSince == nil { state.missingSince = uptime }
        if uptime - (state.missingSince ?? uptime) >= rule.graceSeconds {
          if let id = state.holdID { engine.stop(id: id, reason: .conditionEnded, now: now) }
          state.holdID = nil
        }
        statuses[rule.id] =
          state.holdID == nil ? "Waiting for conditions" : "Ending after grace period"
        continue
      }
      state.missingSince = nil
      if let id = state.holdID, !engine.holds.contains(where: { $0.id == id }) {
        state.holdID = nil
        state.suppressed = true
      }
      if state.suppressed {
        statuses[rule.id] = "Stopped until conditions change"
        continue
      }
      if state.matchedSince == nil { state.matchedSince = uptime }
      guard uptime - (state.matchedSince ?? uptime) >= rule.dwellSeconds else {
        statuses[rule.id] = "Waiting for dwell period"
        continue
      }
      if state.holdID == nil {
        do {
          state.holdID = try engine.start(
            source: .trigger, label: rule.name, displayAwake: rule.displayAwake,
            lowPowerOverride: rule.lowPowerOverride, now: now
          ).id
        } catch {
          statuses[rule.id] = error.localizedDescription
          continue
        }
      }
      statuses[rule.id] = "Keeping awake"
    }
  }
}
