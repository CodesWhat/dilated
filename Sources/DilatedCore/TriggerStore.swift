import Foundation

public struct TriggerStore: Sendable {
  public let directory: URL
  private var legacyFile: URL { directory.appendingPathComponent("triggers.json") }
  private var file: URL { directory.appendingPathComponent("triggers-v2.json") }

  public init(directory: URL) { self.directory = directory }

  public func load() throws -> [TriggerRule] {
    let legacy = try readLegacy()
    guard FileManager.default.fileExists(atPath: file.path) else {
      if FileManager.default.fileExists(atPath: legacyFile.path) {
        try persist(legacy, previous: legacy)
      }
      return legacy
    }
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
    guard Self.supportedSchemas.contains(record.schemaVersion) else {
      throw StoreError(
        "These triggers need a newer version of Dilated. Saved files were kept.")
    }
    try validate(record.rules)
    try validate(record.legacy)
    if let pending = record.pendingLegacy {
      try validate(pending)
      guard legacy == pending || legacy == record.legacy else {
        throw StoreError(
          "Trigger files changed during an interrupted save. Restore a full data backup before editing; both files were kept."
        )
      }
      try persist(record.rules, previous: legacy)
      return record.rules
    }
    guard FileManager.default.fileExists(atPath: legacyFile.path) else { return record.rules }
    let baseline = Dictionary(uniqueKeysWithValues: record.legacy.map { ($0.id, $0) })
    let current = Dictionary(uniqueKeysWithValues: legacy.map { ($0.id, $0) })
    var rules = record.rules.filter { baseline[$0.id] == nil || current[$0.id] != nil }
    for rule in legacy where baseline[rule.id] != rule {
      if let index = rules.firstIndex(where: { $0.id == rule.id }) {
        guard baseline[rule.id] != nil else {
          throw StoreError(
            "Older and newer trigger files contain conflicting rule IDs. Both files were kept.")
        }
        rules[index] = rule
      } else {
        rules.append(rule)
      }
    }
    try validate(rules)
    return rules
  }

  public func save(_ rules: [TriggerRule]) throws {
    try validate(rules)
    // Refuse to overwrite unreadable or conflicting data after a failed load.
    _ = try load()
    let previous = try readLegacy()
    try persist(rules, previous: previous)
  }

  private func persist(_ rules: [TriggerRule], previous: [TriggerRule]) throws {
    let projection = rules.filter { rule in
      !rule.focusControlled
        && rule.criteria.allSatisfy { criterion in
          switch criterion {
          case .networkThroughput, .diskThroughput: false
          case .application, .process, .processInstance, .schedule, .power, .battery, .displays,
            .mirrored, .network, .gateway, .dns, .wifi, .volume, .audioOutput, .usb, .bluetooth,
            .cpu, .idle:
            true
          }
        }
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // Preserve the complete rules before replacing the older reader's projection.
    // The pending record recognizes either side of an interrupted projection write.
    try write(
      Record(
        schemaVersion: schema(for: rules), rules: rules, legacy: previous,
        pendingLegacy: projection), to: file)
    try write(projection, to: legacyFile)
    try write(Record(schemaVersion: schema(for: rules), rules: rules, legacy: projection), to: file)
    // A failed backup must not fail a save that already landed.
    try? rotateBackups()
  }

  public static let backupLimit = 3
  private var backupDirectory: URL { directory.appendingPathComponent("trigger-backups") }

  /// Backups newest first. Names embed a zero-padded millisecond stamp, so name order is age order.
  private func backupFiles() -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
    return names.filter { $0.hasPrefix("triggers-v2-") && $0.hasSuffix(".json") }
      .sorted(by: >).map { backupDirectory.appendingPathComponent($0) }
  }

  /// Keeps a rolling copy of the last good file after each successful save.
  private func rotateBackups() throws {
    let data = try Data(contentsOf: file)
    let existing = backupFiles()
    if let newest = existing.first, (try? Data(contentsOf: newest)) == data { return }
    try FileManager.default.createDirectory(
      at: backupDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var stamp = Int(Date().timeIntervalSince1970 * 1000)
    if let newest = existing.first, let last = Self.stamp(of: newest), stamp <= last {
      stamp = last + 1
    }
    let destination = backupDirectory.appendingPathComponent(
      "triggers-v2-" + String(format: "%016d", stamp) + ".json")
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    for stale in backupFiles().dropFirst(Self.backupLimit) {
      try? FileManager.default.removeItem(at: stale)
    }
  }

  private static func stamp(of url: URL) -> Int? {
    Int(url.lastPathComponent.dropFirst("triggers-v2-".count).dropLast(".json".count))
  }

  private func loadableBackup() -> (url: URL, record: Record)? {
    for url in backupFiles() {
      guard let data = try? Data(contentsOf: url),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        Self.supportedSchemas.contains(record.schemaVersion),
        (try? validate(record.rules)) != nil, (try? validate(record.legacy)) != nil
      else { continue }
      return (url, record)
    }
    return nil
  }

  public struct Recovery: Equatable, Sendable {
    public var backupDate: Date
    public var ruleCount: Int
    /// The unreadable file was written by a newer Dilated.
    public var currentIsNewerSchema: Bool

    public var confirmation: String {
      let kept =
        currentIsNewerSchema
        ? "The newer file stays beside it, renamed, and isn't downgraded or deleted."
        : "The unreadable file stays beside it, renamed, and isn't deleted."
      return "Restore \(ruleCount) automation rule\(ruleCount == 1 ? "" : "s") saved "
        + backupDate.formatted(date: .abbreviated, time: .shortened) + "? " + kept
    }
  }

  /// What a restore would bring back, or nil when the store loads fine or no backup loads.
  public func recovery() -> Recovery? {
    guard (try? load()) == nil, let backup = loadableBackup() else { return nil }
    let date =
      (try? FileManager.default.attributesOfItem(atPath: backup.url.path)[.modificationDate]
        as? Date) ?? Date(timeIntervalSince1970: Double(Self.stamp(of: backup.url) ?? 0) / 1000)
    return Recovery(
      backupDate: date, ruleCount: backup.record.rules.count,
      currentIsNewerSchema: currentIsNewerSchema())
  }

  private func currentIsNewerSchema() -> Bool {
    struct Header: Decodable { var schemaVersion: Int }
    guard let data = try? Data(contentsOf: file),
      let header = try? JSONDecoder().decode(Header.self, from: data)
    else { return false }
    return !Self.supportedSchemas.contains(header.schemaVersion)
  }

  /// Replaces the unreadable files with the newest backup that loads. The unreadable files are
  /// renamed beside the store, never deleted. Throws without `confirmed`.
  @discardableResult
  public func restoreLastGood(confirmed: Bool) throws -> [TriggerRule] {
    guard confirmed else { throw StoreError("Restoring triggers needs confirmation.") }
    guard (try? load()) == nil else { throw StoreError("Triggers load fine; nothing to restore.") }
    guard let backup = loadableBackup() else {
      throw StoreError("No readable trigger backup was found. Saved files were kept.")
    }
    let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
    var moved: [(from: URL, to: URL)] = []
    do {
      for url in [file, legacyFile] where FileManager.default.fileExists(atPath: url.path) {
        let name = url.deletingPathExtension().lastPathComponent
        var aside = directory.appendingPathComponent("\(name).unreadable-\(stamp).json")
        var counter = 1
        while FileManager.default.fileExists(atPath: aside.path) {
          aside = directory.appendingPathComponent("\(name).unreadable-\(stamp)-\(counter).json")
          counter += 1
        }
        try FileManager.default.moveItem(at: url, to: aside)
        moved.append((url, aside))
      }
      try persist(backup.record.rules, previous: [])
    } catch {
      // Put the unreadable files back so a failed restore leaves the store as it was.
      for pair in moved.reversed() {
        try? FileManager.default.removeItem(at: pair.from)
        try? FileManager.default.moveItem(at: pair.to, to: pair.from)
      }
      throw error
    }
    return try load()
  }

  /// Version 1.0.0 ignores `focusControlled` and rejects any schemaVersion other than 1, so a
  /// file holding Focus-controlled rules is stamped 2. After a downgrade 1.0.0 then refuses the
  /// file and keeps it, instead of running those rules unconditionally.
  private static let supportedSchemas = [1, 2]

  private func schema(for rules: [TriggerRule]) -> Int {
    rules.contains(where: \.focusControlled) ? 2 : 1
  }

  private func readLegacy() throws -> [TriggerRule] {
    guard FileManager.default.fileExists(atPath: legacyFile.path) else { return [] }
    let rules = try JSONDecoder().decode([TriggerRule].self, from: Data(contentsOf: legacyFile))
    try validate(rules)
    return rules
  }

  private func validate(_ rules: [TriggerRule]) throws {
    guard rules.count <= 100, Set(rules.map(\.id)).count == rules.count,
      rules.allSatisfy({ $0.validationMessage == nil })
    else {
      throw StoreError(
        "Saved triggers contain invalid rules. Saved files were kept.")
    }
  }

  private func write(_ value: some Encodable, to destination: URL) throws {
    try JSONEncoder().encode(value).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  private struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
  }

  private struct Record: Codable {
    var schemaVersion: Int
    var rules: [TriggerRule]
    var legacy: [TriggerRule]
    var pendingLegacy: [TriggerRule]?

    init(
      schemaVersion: Int = 1, rules: [TriggerRule], legacy: [TriggerRule],
      pendingLegacy: [TriggerRule]? = nil
    ) {
      self.schemaVersion = schemaVersion
      self.rules = rules
      self.legacy = legacy
      self.pendingLegacy = pendingLegacy
    }
  }
}
