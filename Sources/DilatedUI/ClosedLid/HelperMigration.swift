import DilatedCore
import Foundation
import OSLog
import Observation
import ServiceManagement

@MainActor protocol HelperUnregistering: AnyObject {
  var status: SMAppService.Status { get }
  func unregister() async throws
}

@MainActor private final class SystemHelperRegistration: HelperUnregistering {
  private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
  var status: SMAppService.Status { service.status }
  func unregister() async throws { try await service.unregister() }
}

/// What the one-time cleanup of the retired privileged helper found. Kept on disk so Settings can
/// show it after launch, until the user dismisses it.
public struct HelperMigrationRecord: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    /// The helper is unregistered and its job is gone. Sleep was already normal.
    case removed
    /// The helper is gone and Dilated turned sleep back on through the sudo rule.
    case restoredSleep
    /// The helper is gone but sleep is still off. "Restore normal sleep" fixes it.
    case needsRestore
    /// The helper couldn't be unregistered, or its job is still loaded.
    case failed
  }

  public var outcome: Outcome
  public var message: String
  public var date: Date

  public var needsAttention: Bool { outcome == .needsRestore || outcome == .failed }
}

/// Launch-time cleanup for installs that still have the old privileged helper registered.
/// Never throws and never blocks launch: the result lands in `record` for the UI.
@MainActor @Observable public final class HelperMigration {
  public static let fileName = "helper-migration.json"

  public private(set) var record: HelperMigrationRecord?
  public private(set) var running = false
  @ObservationIgnored private let service: any HelperUnregistering
  @ObservationIgnored private let jobState: @Sendable () async -> PackageHelperCheck.JobState
  @ObservationIgnored private let readPower: () -> ClosedLidReadback
  @ObservationIgnored private let hasSessionMarker: () -> Bool
  @ObservationIgnored private let revertSleep: () async -> Bool
  @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
  @ObservationIgnored private let jobAttempts: Int
  @ObservationIgnored private let file: URL
  @ObservationIgnored private let now: () -> Date

  public convenience init(stateDirectory: URL) {
    self.init(
      service: SystemHelperRegistration(), stateDirectory: stateDirectory,
      revertSleep: {
        let driver = SerialPowerDriver(runner: SudoPowerRunner())
        return (try? await driver.setSleepDisabled(false))?.confirmedDisabled == true
      })
  }

  init(
    service: any HelperUnregistering, stateDirectory: URL,
    jobState: @escaping @Sendable () async -> PackageHelperCheck.JobState = {
      await PackageHelperCheck.helperJobState()
    },
    readPower: @escaping () -> ClosedLidReadback = NativeClosedLidPower.readback,
    hasSessionMarker: (() -> Bool)? = nil,
    revertSleep: @escaping () async -> Bool,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    jobAttempts: Int = 10, now: @escaping () -> Date = { Date() }
  ) {
    self.service = service
    self.jobState = jobState
    self.readPower = readPower
    self.hasSessionMarker =
      hasSessionMarker ?? { ClosedLidMarkerStore(directory: stateDirectory).read() != nil }
    self.revertSleep = revertSleep
    self.sleep = sleep
    self.jobAttempts = jobAttempts
    self.now = now
    file = stateDirectory.appendingPathComponent(Self.fileName)
    record = Self.load(file)
  }

  public var needsAttention: Bool { record?.needsAttention == true }

  public func dismiss() {
    record = nil
    try? FileManager.default.removeItem(at: file)
  }

  /// Called after "Restore normal sleep" succeeds, so a stale "sleep is still off" notice goes away.
  public func sleepRestored() {
    guard record?.outcome == .needsRestore else { return }
    save(.init(outcome: .restoredSleep, message: "Normal sleep is back on.", date: now()))
  }

  public func run() async {
    guard !running else { return }
    running = true
    defer { running = false }
    let status = service.status
    let before = await jobState()
    guard status == .enabled || status == .requiresApproval || before == .loaded else { return }
    let sleepWasDisabled = Self.sleepIsDisabled(readPower())
    var failure: String?
    do { try await service.unregister() } catch { failure = error.localizedDescription }
    let gone = await confirmJobGone()
    guard gone else {
      let detail = failure ?? "launchd still lists the job."
      Logger(subsystem: HelperIdentity.appID, category: "HelperMigration").error(
        "Helper still present after unregister: \(detail, privacy: .public)")
      save(
        .init(
          outcome: .failed,
          message:
            "Dilated couldn't remove its old background helper (\(detail)). Turn off Dilated under Login Items & Extensions in System Settings.",
          date: now()))
      return
    }
    guard sleepWasDisabled, Self.sleepIsDisabled(readPower()), !hasSessionMarker() else {
      save(.init(outcome: .removed, message: "Removed the old background helper.", date: now()))
      return
    }
    if await revertSleep(), !Self.sleepIsDisabled(readPower()) {
      save(
        .init(
          outcome: .restoredSleep,
          message: "Removed the old background helper and turned normal sleep back on.",
          date: now()))
    } else {
      save(
        .init(
          outcome: .needsRestore,
          message:
            "Removed the old background helper, but it left sleep turned off. Use Restore normal sleep.",
          date: now()))
    }
  }

  private func confirmJobGone() async -> Bool {
    for attempt in 0..<max(jobAttempts, 1) {
      if await jobState() == .absent { return true }
      if attempt < jobAttempts - 1 { await sleep(.milliseconds(200)) }
    }
    return false
  }

  /// macOS reports that sleep is disabled.
  private static func sleepIsDisabled(_ readback: ClosedLidReadback) -> Bool {
    readback.effectiveDisabled == true || readback.storedDisabled == true
  }

  private func save(_ value: HelperMigrationRecord) {
    record = value
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try encoder.encode(value).write(to: file, options: .atomic)
    } catch {
      Logger(subsystem: HelperIdentity.appID, category: "HelperMigration").error(
        "Couldn't save the migration result: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func load(_ file: URL) -> HelperMigrationRecord? {
    guard let data = try? Data(contentsOf: file), data.count <= 16384 else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(HelperMigrationRecord.self, from: data)
  }
}
