import Foundation
import Observation

@MainActor @Observable final class DriveAliveController {
  typealias Schedule =
    @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)
  private let pulse: @MainActor (DriveAliveVolume) async throws -> Void
  private let schedule: Schedule
  private(set) var statuses: [String: String] = [:]
  @ObservationIgnored private var settings = DriveAliveSettings()
  @ObservationIgnored private var allowed = false
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var restartRequested = false
  @ObservationIgnored private var cancelTimer: (@MainActor () -> Void)?
  @ObservationIgnored private var runningTask: Task<Void, Never>?

  init(
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
    self.pulse = pulse
    self.schedule = schedule
  }

  func configure(_ settings: DriveAliveSettings, awake: Bool, paused: Bool) {
    guard !stopped else { return }
    let allowed =
      settings.enabled && !settings.volumes.isEmpty && settings.validationMessage == nil
      && !paused && (!settings.onlyWhileAwake || awake)
    guard self.settings != settings || self.allowed != allowed else { return }
    self.settings = settings
    self.allowed = allowed
    generation += 1
    cancelTimer?()
    cancelTimer = nil
    runningTask?.cancel()
    restartRequested = allowed
    statuses = statuses.filter { entry in settings.volumes.contains { $0.id == entry.key } }
    if allowed && runningTask == nil { startCycle() }
  }

  private func startCycle() {
    guard allowed, !stopped, runningTask == nil else { return }
    restartRequested = false
    let current = generation
    let volumes = settings.volumes
    runningTask = Task { [weak self] in
      guard let self else { return }
      for volume in volumes {
        guard !Task.isCancelled, self.allowed, self.generation == current else { break }
        do {
          try await self.pulse(volume)
          if self.generation == current { self.statuses[volume.id] = "Active" }
        } catch {
          if self.generation == current { self.statuses[volume.id] = error.localizedDescription }
        }
      }
      self.runningTask = nil
      guard self.allowed, !self.stopped else { return }
      if self.restartRequested {
        self.startCycle()
      } else if self.generation == current {
        self.cancelTimer = self.schedule(Double(self.settings.intervalSeconds)) { [weak self] in
          guard let self, self.generation == current, self.allowed, !self.stopped else { return }
          self.cancelTimer = nil
          self.startCycle()
        }
      }
    }
  }

  func stop() {
    stopped = true
    allowed = false
    generation += 1
    cancelTimer?()
    cancelTimer = nil
    runningTask?.cancel()
    restartRequested = false
  }

  isolated deinit { stop() }
}
