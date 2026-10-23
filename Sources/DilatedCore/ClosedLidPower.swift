import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public struct ClosedLidReadback: Codable, Equatable, Sendable {
  public var effectiveDisabled: Bool?
  public var storedDisabled: Bool?
  public var confirmedEnabled: Bool { effectiveDisabled == true && storedDisabled == true }
  public var confirmedDisabled: Bool { effectiveDisabled == false && storedDisabled == false }

  public init(effectiveDisabled: Bool? = nil, storedDisabled: Bool? = nil) {
    self.effectiveDisabled = effectiveDisabled
    self.storedDisabled = storedDisabled
  }
}
public enum PowerCommand: Equatable, Sendable {
  case setSleepDisabled(Bool)
  case sleep
}
public protocol PowerCommandRunning: Sendable {
  func run(_ command: PowerCommand) async throws
}
public protocol ClosedLidPowerControlling: Sendable {
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback
  func readback() async -> ClosedLidReadback
  func sleep() async throws
}
public enum ClosedLidPowerError: Error, Sendable, LocalizedError {
  case requiresRoot, commandTimedOut
  case commandFailed(Int32)
  case readbackMismatch,
    invalidDeadline, childDidNotExit
  case sleepFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .requiresRoot: "The approved Dilated helper is required for this operation."
    case .commandTimedOut: "The power-setting operation timed out."
    case .commandFailed(let status): "The power-setting operation failed (\(status))."
    case .readbackMismatch: "macOS didn't confirm the requested power setting."
    case .invalidDeadline: "The power operation has an invalid deadline."
    case .childDidNotExit: "The power-setting process didn't exit after termination."
    case .sleepFailed(let status): "macOS couldn't start sleep (\(status))."
    }
  }
}

public actor SerialPowerDriver: ClosedLidPowerControlling {
  private let runner: any PowerCommandRunning
  private let read: @Sendable () async -> ClosedLidReadback
  private var tail: Task<ClosedLidReadback, any Error>?

  public init(
    runner: any PowerCommandRunning = NativePowerRunner(),
    readback: @escaping @Sendable () async -> ClosedLidReadback = {
      NativeClosedLidPower.readback()
    }
  ) {
    self.runner = runner
    self.read = readback
  }
  public func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    try await enqueue(.setSleepDisabled(disabled)).value
  }
  public func sleep() async throws { _ = try await enqueue(.sleep).value }
  public func readback() async -> ClosedLidReadback { await read() }

  func enqueue(_ command: PowerCommand) -> Task<ClosedLidReadback, any Error> {
    let previous = tail
    let runner = self.runner
    let read = self.read
    let operation = Task<ClosedLidReadback, any Error> {
      _ = await previous?.result
      try await runner.run(command)
      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      repeat {
        let state = await read()
        let expected: Bool
        switch command {
        case .setSleepDisabled(let disabled):
          expected = disabled ? state.confirmedEnabled : state.confirmedDisabled
        case .sleep: expected = state.confirmedDisabled
        }
        if expected { return state }
        try await Task.sleep(for: .milliseconds(50))
      } while ContinuousClock.now < deadline
      throw ClosedLidPowerError.readbackMismatch
    }
    tail = operation
    return operation
  }
}

public struct NativePowerRunner: PowerCommandRunning {
  public init() {}
  public func run(_ command: PowerCommand) async throws {
    guard geteuid() == 0 else { throw ClosedLidPowerError.requiresRoot }
    switch command {
    case .setSleepDisabled(let disabled):
      let result = try await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/usr/bin/pmset"),
        arguments: ["-a", "disablesleep", disabled ? "1" : "0"], timeout: 3)
      if result.timedOut { throw ClosedLidPowerError.commandTimedOut }
      guard result.status == 0 else { throw ClosedLidPowerError.commandFailed(result.status) }
    case .sleep:
      let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
      guard connection != 0 else { throw ClosedLidPowerError.sleepFailed(kIOReturnNotFound) }
      defer { IOServiceClose(connection) }
      let status = IOPMSleepSystem(connection)
      guard status == kIOReturnSuccess else { throw ClosedLidPowerError.sleepFailed(status) }
    }
  }
}

public enum NativeClosedLidPower {
  public static func readback() -> ClosedLidReadback {
    let file = URL(fileURLWithPath: "/Library/Preferences/com.apple.PowerManagement.plist")
    let data = try? Data(contentsOf: file)
    let plist = data.flatMap {
      try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
    let stored = (plist?["SystemPowerSettings"] as? [String: Any])?["SleepDisabled"] as? Bool
    return ClosedLidReadback(
      effectiveDisabled: rootProperty("SleepDisabled"), storedDisabled: stored)
  }

  public static func environment() -> ClosedLidEnvironment {
    var environment = ClosedLidEnvironment()
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    {
      switch source {
      case kIOPSACPowerValue: environment.powerSource = .ac
      case kIOPSBatteryPowerValue: environment.powerSource = .battery
      default: environment.powerSource = .unknown
      }
    }
    environment.batteryPercent = SystemPower.read().batteryPercent
    environment.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: environment.thermal = .nominal
    case .fair: environment.thermal = .fair
    case .serious: environment.thermal = .serious
    case .critical: environment.thermal = .critical
    @unknown default: environment.thermal = .unknown
    }
    environment.lidClosed = rootProperty("AppleClamshellState")
    return environment
  }

  private static func rootProperty(_ key: String) -> Bool? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? Bool
  }
}
