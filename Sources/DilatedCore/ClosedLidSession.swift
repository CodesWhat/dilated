import Darwin
import Foundation

/// Written before sleep is disabled and removed only after a confirmed revert, so a dead app
/// always leaves evidence that this process (and not Amphetamine or the user) disabled sleep.
public struct ClosedLidSessionMarker: Codable, Equatable, Sendable {
  public var pid: Int32
  public var processStartMicros: Int64
  public var generation: UUID
  public var enabledAt: Date

  public init(pid: Int32, processStartMicros: Int64, generation: UUID, enabledAt: Date) {
    self.pid = pid
    self.processStartMicros = processStartMicros
    self.generation = generation
    self.enabledAt = enabledAt
  }
}

public struct ClosedLidMarkerStore: Sendable {
  public static let fileName = "closed-lid-session.json"
  public static let lockFileName = "closed-lid-session.lock"
  public let file: URL

  public init(directory: URL) { file = directory.appendingPathComponent(Self.fileName) }
  public init(file: URL) { self.file = file }

  /// The advisory lock that serializes the app and the watchdog around the marker and the revert.
  public var lockFile: URL {
    file.deletingLastPathComponent().appendingPathComponent(Self.lockFileName)
  }

  /// Takes the lock without blocking a thread: retries `flock(LOCK_NB)` with a short sleep until
  /// `timeout`, so callers on an actor never wait indefinitely.
  public func acquireLock(
    timeout: Duration = .seconds(5), retry: Duration = .milliseconds(25)
  ) async throws -> ClosedLidFileLock {
    try await ClosedLidFileLock.acquire(at: lockFile, timeout: timeout, retry: retry)
  }

  public func read() -> ClosedLidSessionMarker? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? Self.decoder.decode(ClosedLidSessionMarker.self, from: data)
  }

  /// Atomic: readers see the old marker or the new one, never a partial file.
  public func write(_ marker: ClosedLidSessionMarker) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Self.encoder.encode(marker).write(to: file, options: .atomic)
  }

  /// Removes the marker only when it still belongs to `generation`.
  public func clear(generation: UUID) {
    guard read()?.generation == generation else { return }
    try? FileManager.default.removeItem(at: file)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public enum ClosedLidSessionError: Error, Sendable, LocalizedError {
  case lockTimeout, startTimeUnreadable

  public var errorDescription: String? {
    switch self {
    case .lockTimeout: "Closed-lid state is busy. Try again."
    case .startTimeUnreadable:
      "Dilated couldn't read its own start time, so it won't disable sleep."
    }
  }
}

/// An exclusive advisory `flock` on a file. Released by `release()` or when the object goes away.
public final class ClosedLidFileLock: @unchecked Sendable {
  private let guardLock = NSLock()
  private var descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { release() }

  public static func acquire(
    at url: URL, timeout: Duration, retry: Duration
  ) async throws -> ClosedLidFileLock {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ClosedLidSessionError.lockTimeout }
    let deadline = ContinuousClock.now + timeout
    while true {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        return ClosedLidFileLock(descriptor: descriptor)
      }
      guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
        close(descriptor)
        throw ClosedLidSessionError.lockTimeout
      }
      do { try await Task.sleep(for: retry) } catch {
        close(descriptor)
        throw error
      }
    }
  }

  public func release() {
    let held = guardLock.withLock {
      let held = descriptor
      descriptor = -1
      return held
    }
    if held >= 0 {
      flock(held, LOCK_UN)
      close(held)
    }
  }
}

public enum ProcessStartTime {
  /// Kernel start time of a live process in microseconds, or nil when it's gone or a zombie.
  /// A pid with a different start time is a different process.
  public static func micros(pid: Int32) -> Int64? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid, info.kp_proc.p_stat != SZOMB
    else { return nil }
    let started = info.kp_proc.p_un.__p_starttime
    return Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
  }
}

public struct ClosedLidWatchdogLaunch: Equatable, Sendable {
  public var pid: Int32
  public var marker: URL
  public var generation: UUID

  public init(pid: Int32, marker: URL, generation: UUID) {
    self.pid = pid
    self.marker = marker
    self.generation = generation
  }
}

/// Wraps the power driver for the local (sudo) path: marker before enable, marker removed only
/// after a confirmed revert, a stale marker from a dead app reverted on first use, and one
/// watchdog launch per session generation.
public actor ClosedLidSessionGuard: ClosedLidPowerControlling {
  public enum Recovery: Equatable, Sendable {
    case notChecked
    case clean
    /// A dead app's marker was found and sleep was restored.
    case reverted
    /// Sleep is disabled with no marker of ours. Left alone.
    case foreignSleepDisabled
    /// The marker's app is still running (another Dilated on this state directory).
    case activeElsewhere
    /// A stale marker is still there because the revert failed. Retried on every power call.
    case failed(String)
  }

  private let power: any ClosedLidPowerControlling
  private let store: ClosedLidMarkerStore
  private let startMicros: @Sendable (Int32) -> Int64?
  private let pid: Int32
  private let now: @Sendable () -> Date
  private let launchWatchdog: @Sendable (ClosedLidWatchdogLaunch) throws -> Void
  private var session: ClosedLidSessionMarker?
  private var settled = false
  private var recoveryError: (any Error)?
  public private(set) var recovery = Recovery.notChecked

  public init(
    power: any ClosedLidPowerControlling, store: ClosedLidMarkerStore,
    pid: Int32 = getpid(),
    startMicros: @escaping @Sendable (Int32) -> Int64? = { ProcessStartTime.micros(pid: $0) },
    now: @escaping @Sendable () -> Date = { Date() },
    launchWatchdog: @escaping @Sendable (ClosedLidWatchdogLaunch) throws -> Void = { _ in }
  ) {
    self.power = power
    self.store = store
    self.pid = pid
    self.startMicros = startMicros
    self.now = now
    self.launchWatchdog = launchWatchdog
  }

  public func readback() async -> ClosedLidReadback { await power.readback() }
  public func sleep() async throws { try await power.sleep() }

  public func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    await recoverIfNeeded()
    if let recoveryError { throw recoveryError }
    return disabled ? try await enable() : try await disable()
  }

  private func enable() async throws -> ClosedLidReadback {
    let lock = try await store.acquireLock()
    defer { lock.release() }
    var created: ClosedLidSessionMarker?
    if session == nil {
      // A zero start time would make the watchdog think the live app is already gone.
      guard let start = startMicros(pid), start > 0 else {
        throw ClosedLidSessionError.startTimeUnreadable
      }
      let marker = ClosedLidSessionMarker(
        pid: pid, processStartMicros: start, generation: UUID(), enabledAt: now())
      try store.write(marker)
      session = marker
      created = marker
      do {
        try launchWatchdog(
          ClosedLidWatchdogLaunch(pid: pid, marker: store.file, generation: marker.generation))
      } catch {
        store.clear(generation: marker.generation)
        session = nil
        throw error
      }
    }
    do {
      return try await power.setSleepDisabled(true)
    } catch {
      // No confirmed enable: drop the session. Deleting the marker makes the watchdog exit.
      if let created {
        store.clear(generation: created.generation)
        session = nil
      }
      throw error
    }
  }

  private func disable() async throws -> ClosedLidReadback {
    let lock = try await store.acquireLock()
    defer { lock.release() }
    if session == nil {
      if recovery == .activeElsewhere { return await power.readback() }
      if store.read() == nil {
        let observed = await power.readback()
        if observed.effectiveDisabled == true || observed.storedDisabled == true {
          recovery = .foreignSleepDisabled
          return observed
        }
        if recovery == .foreignSleepDisabled { recovery = .clean }
      }
    }
    let observed = try await power.setSleepDisabled(false)
    if observed.confirmedDisabled, let session {
      store.clear(generation: session.generation)
      self.session = nil
    }
    return observed
  }

  /// Called after the password-backed restore. Clears a failed revert once macOS confirms sleep
  /// is back on; returns false (and changes nothing) when it isn't.
  public func acknowledgeManualRestore() async -> Bool {
    guard await power.readback().confirmedDisabled else { return false }
    if let lock = try? await store.acquireLock() {
      if let marker = store.read() { store.clear(generation: marker.generation) }
      lock.release()
    }
    session = nil
    recoveryError = nil
    recovery = .reverted
    settled = true
    return true
  }

  private func recoverIfNeeded() async {
    guard !settled, session == nil else { return }
    recoveryError = nil
    guard let marker = store.read() else {
      recovery = .clean
      settled = true
      return
    }
    if startMicros(marker.pid) == marker.processStartMicros {
      recovery = .activeElsewhere
      return
    }
    do {
      let lock = try await store.acquireLock()
      defer { lock.release() }
      // The marker may have been replaced or cleared while waiting for the lock.
      guard store.read()?.generation == marker.generation else { return }
      let observed = try await power.setSleepDisabled(false)
      guard observed.confirmedDisabled else { throw ClosedLidPowerError.readbackMismatch }
      store.clear(generation: marker.generation)
      recovery = .reverted
      settled = true
    } catch {
      recovery = .failed(error.localizedDescription)
      recoveryError = error
    }
  }
}
