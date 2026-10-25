import Foundation
import Observation

@MainActor @Observable final class DriveAliveController {
  typealias Schedule =
    @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)
  private let clock: @MainActor () -> TimeInterval
  private let pulse: @MainActor (DriveAliveVolume) async throws -> Void
  private let schedule: Schedule
  private(set) var statuses: [String: String] = [:]
  @ObservationIgnored private var settings = DriveAliveSettings()
  @ObservationIgnored private var eligibleVolumes: [DriveAliveVolume] = []
  @ObservationIgnored private var due: [String: TimeInterval] = [:]
  @ObservationIgnored private var currentVolumeID: String?
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var scheduleID = UUID()
  @ObservationIgnored private var cancelTimer: (@MainActor () -> Void)?
  @ObservationIgnored private var runningTask: Task<Void, Never>?

  init(
    clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pulse: @escaping @MainActor (DriveAliveVolume) async throws -> Void = NativeDriveAlive.pulse,
    schedule: @escaping Schedule = { seconds, fire in
      let timer = Timer(timeInterval: seconds, repeats: false) { _ in
        MainActor.assumeIsolated { fire() }
      }
      timer.tolerance = min(5, seconds / 10)
      RunLoop.main.add(timer, forMode: .common)
      return { timer.invalidate() }
    }
  ) {
    self.clock = clock
    self.pulse = pulse
    self.schedule = schedule
  }

  func configure(_ settings: DriveAliveSettings, awake: Bool, paused: Bool) {
    guard !stopped else { return }
    let eligible = settings.eligibleVolumes(awake: awake, paused: paused)
    let changedSettings = self.settings != settings
    guard changedSettings || eligibleVolumes != eligible else { return }
    let previousIDs = Set(eligibleVolumes.map(\.id))
    let ids = Set(eligible.map(\.id))
    self.settings = settings
    eligibleVolumes = eligible
    invalidateTimer()
    if changedSettings {
      generation += 1
      due.removeAll(keepingCapacity: true)
      runningTask?.cancel()
    } else if let currentVolumeID, !ids.contains(currentVolumeID) {
      runningTask?.cancel()
    }
    due = due.filter { ids.contains($0.key) }
    let now = clock()
    for volume in eligible where changedSettings || !previousIDs.contains(volume.id) {
      due[volume.id] = now
    }
    statuses = statuses.filter { ids.contains($0.key) }
    if runningTask == nil { startNext() }
  }

  private func invalidateTimer() {
    scheduleID = UUID()
    cancelTimer?()
    cancelTimer = nil
  }

  private func startNext() {
    guard !stopped, !eligibleVolumes.isEmpty, runningTask == nil else { return }
    invalidateTimer()
    let now = clock()
    let volumes = eligibleVolumes.filter { (due[$0.id] ?? now) <= now }
    guard !volumes.isEmpty else {
      guard let next = due.values.min() else { return }
      let current = scheduleID
      cancelTimer = schedule(max(0, next - now)) { [weak self] in
        guard let self, self.scheduleID == current, !self.stopped else { return }
        self.cancelTimer = nil
        self.startNext()
      }
      return
    }
    let current = generation
    runningTask = Task { [weak self] in
      guard let self else { return }
      for volume in volumes {
        guard !Task.isCancelled, !self.stopped, self.generation == current else { break }
        guard self.eligibleVolumes.contains(where: { $0.id == volume.id }) else { continue }
        self.currentVolumeID = volume.id
        let result: String
        do {
          try await self.pulse(volume)
          result = "Active"
        } catch { result = error.localizedDescription }
        if !Task.isCancelled, self.generation == current,
          self.eligibleVolumes.contains(where: { $0.id == volume.id })
        {
          self.statuses[volume.id] = result
          self.due[volume.id] = self.clock() + Double(self.settings.intervalSeconds)
        }
        self.currentVolumeID = nil
      }
      self.runningTask = nil
      self.startNext()
    }
  }

  func stop() {
    stopped = true
    eligibleVolumes.removeAll()
    due.removeAll()
    generation += 1
    invalidateTimer()
    runningTask?.cancel()
  }

  isolated deinit { stop() }
}
