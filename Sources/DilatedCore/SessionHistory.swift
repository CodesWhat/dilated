import Foundation

public enum HoldEndReason: String, Codable, CaseIterable, Sendable {
  case stopped, expired, lowBattery, lowPowerMode, conditionEnded, reconfigured
  case sleep, userSwitch, quit, update, packageRemoval, helperFailure, interrupted,
    recordingDisabled

  public var title: String {
    switch self {
    case .stopped: "Stopped"
    case .expired: "Timer ended"
    case .lowBattery: "Battery guard"
    case .lowPowerMode: "Low Power Mode"
    case .conditionEnded: "Conditions ended"
    case .reconfigured: "Trigger changed or paused"
    case .sleep: "Mac went to sleep"
    case .userSwitch: "Switched users"
    case .quit: "Quit"
    case .update: "App update"
    case .packageRemoval: "Prepared for removal"
    case .helperFailure: "Closed-lid start failed"
    case .interrupted: "Interrupted, last checkpoint"
    case .recordingDisabled: "History recording turned off"
    }
  }
}

public struct HoldHistoryEvent: Sendable {
  public let hold: Hold
  public let at: Date
  public let endReason: HoldEndReason?
  public init(hold: Hold, at: Date, endReason: HoldEndReason? = nil) {
    self.hold = hold
    self.at = at
    self.endReason = endReason
  }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let holdID: UUID
  public let source: HoldSource
  public var label: String
  public var startedAt: Date
  public var lastObservedAt: Date
  public var endedAt: Date?
  public var endReason: HoldEndReason?
  public var duration: TimeInterval {
    max(0, (endedAt ?? lastObservedAt).timeIntervalSince(startedAt))
  }

  init(hold: Hold, at: Date) {
    id = UUID()
    holdID = hold.id
    source = hold.source
    label = hold.label
    startedAt = at
    lastObservedAt = at
  }
  mutating func finish(at: Date, reason: HoldEndReason) {
    let end = max(startedAt, at)
    endedAt = end
    lastObservedAt = end
    endReason = reason
  }
  var valid: Bool {
    label.count <= 200 && startedAt.timeIntervalSince1970.isFinite
      && lastObservedAt.timeIntervalSince1970.isFinite && lastObservedAt >= startedAt
      && (endedAt == nil) == (endReason == nil)
      && (endedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= startedAt } ?? true)
  }
}

public struct HistoryStatistics: Sendable {
  public let awakeSeconds: TimeInterval
  public let reasons: Int
  public let completed: Int
}

public struct SessionHistory: Sendable {
  public private(set) var records: [SessionRecord] = []
  private var running: [UUID: SessionRecord] = [:]
  public var active: [SessionRecord] { running.values.sorted { $0.startedAt < $1.startedAt } }
  public init() {}

  public mutating func receive(_ events: [HoldHistoryEvent], now: Date) {
    for event in events {
      if let reason = event.endReason {
        guard var record = running.removeValue(forKey: event.hold.id) else { continue }
        record.label = event.hold.label
        record.finish(at: event.at, reason: reason)
        records.append(record)
      } else if running[event.hold.id] == nil, running.count < 1024 {
        running[event.hold.id] = SessionRecord(hold: event.hold, at: event.at)
      }
    }
    checkpoint(at: now)
    retain(since: now.addingTimeInterval(-90 * 86400), maximumRecords: 2000)
  }
  public mutating func checkpoint(at now: Date) {
    for id in running.keys {
      guard var record = running[id] else { continue }
      record.lastObservedAt = max(record.startedAt, now)
      running[id] = record
    }
  }
  public mutating func finishActive(at now: Date, reason: HoldEndReason) {
    for var record in running.values {
      record.finish(at: now, reason: reason)
      records.append(record)
    }
    running.removeAll()
  }
  public mutating func clear(at now: Date) {
    records.removeAll()
    for id in running.keys {
      running[id]?.startedAt = now
      running[id]?.lastObservedAt = now
    }
  }
  public func statistics(now: Date) -> HistoryStatistics {
    let intervals = (records + active).map { record in
      (record.startedAt, max(record.startedAt, record.endedAt ?? now))
    }.sorted { $0.0 < $1.0 }
    var end = Date.distantPast
    var total: TimeInterval = 0
    for (start, stop) in intervals where stop > end {
      total += stop.timeIntervalSince(max(start, end))
      end = stop
    }
    return HistoryStatistics(
      awakeSeconds: total, reasons: records.count + running.count, completed: records.count)
  }
  mutating func retain(since cutoff: Date, maximumRecords: Int) {
    records = Array(
      records.filter { ($0.endedAt ?? $0.lastObservedAt) >= cutoff }
        .sorted { ($0.endedAt ?? $0.lastObservedAt) < ($1.endedAt ?? $1.lastObservedAt) }
        .suffix(maximumRecords))
  }
  mutating func dropOldest(_ count: Int) { records.removeFirst(min(count, records.count)) }
  static func recovering(records: [SessionRecord], active: [SessionRecord]) -> Self {
    var result = Self()
    result.records = records
    let finished = Set(records.map(\.id))
    for var record in active where !finished.contains(record.id) {
      record.finish(at: record.lastObservedAt, reason: .interrupted)
      result.records.append(record)
    }
    return result
  }
}

public struct HistoryStore: Sendable {
  public let directory: URL
  public let maximumRecords: Int
  public let maximumBytes: Int
  public init(directory: URL, maximumRecords: Int = 2000, maximumBytes: Int = 2 * 1024 * 1024) {
    self.directory = directory
    self.maximumRecords = max(1, maximumRecords)
    self.maximumBytes = max(1024, maximumBytes)
  }
  private var completedFile: URL { directory.appendingPathComponent("history.jsonl") }
  private var activeFile: URL { directory.appendingPathComponent("history-active.json") }

  public func load(now: Date = Date(), retentionDays: Int = 30) throws -> SessionHistory {
    let decoder = JSONDecoder()
    var records: [SessionRecord] = []
    if let data = try read(completedFile, limit: maximumBytes) {
      records = try data.split(separator: 10).map {
        try decoder.decode(SessionRecord.self, from: Data($0))
      }
    }
    let active =
      try read(activeFile, limit: 1024 * 1024).map {
        try decoder.decode([SessionRecord].self, from: $0)
      } ?? []
    guard records.allSatisfy({ $0.valid && $0.endedAt != nil }), active.count <= 1024,
      active.allSatisfy({ $0.valid && $0.endedAt == nil }),
      Set(records.map(\.id)).count == records.count
    else { throw HistoryError("Saved history contains invalid records.") }
    var history = SessionHistory.recovering(records: records, active: active)
    history.retain(
      since: now.addingTimeInterval(-Double(min(90, max(1, retentionDays))) * 86400),
      maximumRecords: maximumRecords)
    return history
  }
  @discardableResult public func save(
    _ history: SessionHistory, now: Date = Date(), retentionDays: Int = 30,
    includingRecords: Bool = true
  ) throws -> SessionHistory {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var history = history
    history.retain(
      since: now.addingTimeInterval(-Double(min(90, max(1, retentionDays))) * 86400),
      maximumRecords: maximumRecords)
    if includingRecords {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var lines = try history.records.map { try encoder.encode($0) }
      var size = lines.reduce(0) { $0 + $1.count + 1 }
      var removed = 0
      while size > maximumBytes, removed < lines.count {
        size -= lines[removed].count + 1
        removed += 1
      }
      history.dropOldest(removed)
      lines.removeFirst(removed)
      var data = Data()
      data.reserveCapacity(size)
      for line in lines {
        data.append(line)
        data.append(10)
      }
      try write(data, to: completedFile)
    }
    try write(JSONEncoder().encode(history.active), to: activeFile)
    return history
  }
  public func export(_ history: SessionHistory, now: Date = Date()) throws -> Data {
    struct Export: Encodable {
      let schema = 1
      let scope = "App-managed awake reasons"
      let exportedAt: Date
      let completed: [SessionRecord]
      let active: [SessionRecord]
      let awakeSeconds: TimeInterval
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(
      Export(
        exportedAt: now, completed: history.records, active: history.active,
        awakeSeconds: history.statistics(now: now).awakeSeconds))
  }
  private func read(_ file: URL, limit: Int) throws -> Data? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw HistoryError("Saved history exceeds its size limit.") }
    return data
  }
  private func write(_ data: Data, to file: URL) throws {
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
public struct HistoryError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
