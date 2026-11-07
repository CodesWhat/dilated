import Foundation

public struct TriggerStore: Sendable {
  public let directory: URL
  private var legacyFile: URL { directory.appendingPathComponent("triggers.json") }
  private var file: URL { directory.appendingPathComponent("triggers-v2.json") }

  public init(directory: URL) { self.directory = directory }

  public func load() throws -> [TriggerRule] {
    let legacy = try readLegacy()
    guard FileManager.default.fileExists(atPath: file.path) else { return legacy }
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
    guard record.schemaVersion == 1 else {
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
      return record.rules
    }
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
    let projection = rules.filter { rule in
      rule.criteria.allSatisfy { criterion in
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
    try write(Record(rules: rules, legacy: previous, pendingLegacy: projection), to: file)
    try write(projection, to: legacyFile)
    try write(Record(rules: rules, legacy: projection), to: file)
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
    var schemaVersion = 1
    var rules: [TriggerRule]
    var legacy: [TriggerRule]
    var pendingLegacy: [TriggerRule]?
  }
}
