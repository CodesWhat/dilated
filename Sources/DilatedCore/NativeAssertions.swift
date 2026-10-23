import Foundation
import IOKit.pwr_mgt

@MainActor public protocol AssertionControlling {
  var activeTypes: Set<String> { get }
  func synchronize(holds: [Hold], now: Date) throws
  func releaseAll()
}

@MainActor public final class NativeAssertions: AssertionControlling {
  private var assertions: [String: IOPMAssertionID] = [:]
  public init() {}
  public var activeTypes: Set<String> {
    Set(assertions.compactMap { type, id in IOPMAssertionCopyProperties(id) == nil ? nil : type })
  }

  public func synchronize(holds: [Hold], now: Date = Date()) throws {
    for type in [
      kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep,
    ] {
      let relevant = holds.filter {
        type == kIOPMAssertionTypePreventUserIdleSystemSleep || $0.displayAwake
      }
      guard !relevant.isEmpty else {
        if let id = assertions.removeValue(forKey: type) { IOPMAssertionRelease(id) }
        continue
      }
      let name = "Dilated: \(relevant[0].label)"
      let duration =
        relevant.contains { $0.expiry == nil }
        ? 90
        : min(
          90, max(1, relevant.compactMap(\.expiry).map { $0.timeIntervalSince(now) }.max() ?? 90))
      if let id = assertions[type] {
        let result = IOPMAssertionSetProperty(
          id, kIOPMAssertionTimeoutKey as CFString, duration as CFNumber)
        if result == kIOReturnSuccess {
          IOPMAssertionSetProperty(id, kIOPMAssertionNameKey as CFString, name as CFString)
          IOPMAssertionSetProperty(
            id, kIOPMAssertionDetailsKey as CFString,
            relevant.map(\.label).joined(separator: ", ") as CFString)
          continue
        }
        IOPMAssertionRelease(id)
        assertions.removeValue(forKey: type)
      }
      let properties: [String: Any] = [
        kIOPMAssertionTypeKey: type, kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
        kIOPMAssertionNameKey: name,
        kIOPMAssertionDetailsKey: relevant.map(\.label).joined(separator: ", "),
        kIOPMAssertionTimeoutKey: duration,
        kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
      ]
      var id: IOPMAssertionID = 0
      let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
      guard result == kIOReturnSuccess else {
        releaseAll()
        throw NSError(
          domain: "Dilated.PowerAssertion", code: Int(result),
          userInfo: [
            NSLocalizedDescriptionKey: "macOS couldn't create the keep-awake assertion (\(result))."
          ])
      }
      assertions[type] = id
    }
  }

  public func releaseAll() {
    for id in assertions.values { IOPMAssertionRelease(id) }
    assertions.removeAll()
  }
}
