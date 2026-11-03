import Darwin
import Foundation
import IOKit.pwr_mgt

/// Read-only view of the system's power assertions. Nothing here can release or modify one.
public protocol PowerAssertionSource {
  /// Raw `IOPMCopyAssertionsByProcess` result, keyed by PID.
  func assertionsByProcess() -> [Int32: [[String: Any]]]
  /// Raw `IOPMCopyAssertionsStatus` result: assertion type to the number of holders.
  func assertionStatus() -> [String: Int]
}

public struct SystemPowerAssertionSource: PowerAssertionSource {
  public init() {}

  public func assertionsByProcess() -> [Int32: [[String: Any]]] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let unmanaged else {
      return [:]
    }
    let raw = unmanaged.takeRetainedValue() as NSDictionary
    var result: [Int32: [[String: Any]]] = [:]
    for (key, value) in raw {
      guard let pid = (key as? NSNumber)?.int32Value else { continue }
      result[pid] = (value as? [[String: Any]]) ?? []
    }
    return result
  }

  public func assertionStatus() -> [String: Int] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess, let unmanaged else {
      return [:]
    }
    let raw = unmanaged.takeRetainedValue() as NSDictionary
    var result: [String: Int] = [:]
    for (key, value) in raw {
      guard let type = key as? String, let count = (value as? NSNumber)?.intValue else { continue }
      result[type] = count
    }
    return result
  }
}

public struct PowerAssertionEntry: Codable, Equatable, Sendable {
  public var pid: Int32
  /// `nil` when the process has exited or its name can't be read.
  public var processName: String?
  public var type: String
  public var name: String?
  /// True when the holder is the running Dilated app.
  public var ours: Bool

  public init(pid: Int32, processName: String?, type: String, name: String?, ours: Bool) {
    self.pid = pid
    self.processName = processName
    self.type = type
    self.name = name
    self.ours = ours
  }

  enum CodingKeys: String, CodingKey {
    case pid
    case processName = "process"
    case type, name, ours
  }

  /// Every key is always present; missing names encode as `null` so the shape is stable.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(pid, forKey: .pid)
    try container.encode(processName, forKey: .processName)
    try container.encode(type, forKey: .type)
    try container.encode(name, forKey: .name)
    try container.encode(ours, forKey: .ours)
  }
}

public struct PowerAssertionReport: Codable, Equatable, Sendable {
  /// The running app's PID, or `nil` when it isn't known (app not running, or an older app).
  public var appPID: Int32?
  public var assertions: [PowerAssertionEntry]
  /// Assertion type to the number of holders system-wide.
  public var summary: [String: Int]

  public init(appPID: Int32?, assertions: [PowerAssertionEntry], summary: [String: Int]) {
    self.appPID = appPID
    self.assertions = assertions
    self.summary = summary
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appPID, forKey: .appPID)
    try container.encode(assertions, forKey: .assertions)
    try container.encode(summary, forKey: .summary)
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var text: String {
    guard !assertions.isEmpty else { return "No power assertions." }
    let lines = assertions.map { entry in
      let owner = entry.processName ?? "unknown process"
      let detail = entry.name.map { "  \"\($0)\"" } ?? ""
      return "\(entry.ours ? "*" : " ") \(owner) (\(entry.pid))  \(entry.type)\(detail)"
    }
    return (lines + (assertions.contains { $0.ours } ? ["* held by Dilated"] : []))
      .joined(separator: "\n")
  }
}

public enum AssertionInspector {
  public static func processName(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let name = String(cString: buffer)
    return name.isEmpty ? nil : name
  }

  public static func report(
    appPID: Int32?,
    source: any PowerAssertionSource = SystemPowerAssertionSource(),
    processName: (Int32) -> String? = AssertionInspector.processName(pid:)
  ) -> PowerAssertionReport {
    var entries: [PowerAssertionEntry] = []
    for (pid, assertions) in source.assertionsByProcess() {
      let holder = processName(pid)
      for assertion in assertions {
        let type = assertion[kIOPMAssertionTypeKey as String] as? String ?? "Unknown"
        let name = (assertion[kIOPMAssertionNameKey as String] as? String).flatMap {
          $0.isEmpty ? nil : $0
        }
        entries.append(
          PowerAssertionEntry(
            pid: pid, processName: holder, type: type, name: name,
            ours: appPID.map { $0 == pid } ?? false))
      }
    }
    entries.sort { ($0.pid, $0.type, $0.name ?? "") < ($1.pid, $1.type, $1.name ?? "") }
    return PowerAssertionReport(
      appPID: appPID, assertions: entries, summary: source.assertionStatus())
  }
}
