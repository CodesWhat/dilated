import DilatedCore
import Foundation
import Observation

enum FeedbackAuthorization: Sendable {
  case unknown, notDetermined, denied, allowed, unavailable
  var title: String {
    switch self {
    case .unknown: "Not checked"
    case .notDetermined: "Not requested"
    case .denied: "Disabled in macOS notification settings"
    case .allowed: "Allowed by macOS"
    case .unavailable: "Available in the installed Dilated app"
    }
  }
}

struct FeedbackNotice: Sendable {
  enum Kind: String, Sendable { case started, ended, reminder }
  let id = UUID()
  let kind: Kind
  let title: String
  let body: String
}

@MainActor protocol FeedbackService: AnyObject {
  func authorization() async -> FeedbackAuthorization
  func requestAuthorization() async throws -> FeedbackAuthorization
  func send(_ notice: FeedbackNotice) async throws
  func cancel(_ ids: [UUID])
}
@MainActor protocol FeedbackSoundPlaying: AnyObject {
  func play(_ choice: FeedbackSound) throws
  func stop()
}

@MainActor @Observable final class FeedbackController {
  private(set) var permission = FeedbackAuthorization.unknown
  private(set) var requestingPermission = false
  private(set) var notificationIssue: String?
  private(set) var soundIssue: String?
  var issue: String? {
    let issues = [notificationIssue, soundIssue].compactMap { $0 }
    return issues.isEmpty ? nil : issues.joined(separator: "\n")
  }
  @ObservationIgnored private let service: any FeedbackService
  @ObservationIgnored private let sounds: any FeedbackSoundPlaying
  @ObservationIgnored private var settings = FeedbackSettings()
  @ObservationIgnored private var known: [UUID: Hold] = [:]
  @ObservationIgnored private var initialized = false
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var nextReminder: TimeInterval?
  @ObservationIgnored private var requests: [FeedbackNotice.Kind: UUID] = [:]
  @ObservationIgnored private var tasks: [FeedbackNotice.Kind: Task<Void, Never>] = [:]

  init(service: any FeedbackService, sounds: any FeedbackSoundPlaying) {
    self.service = service
    self.sounds = sounds
  }

  func refreshPermission() async {
    guard !stopped else { return }
    let value = await service.authorization()
    guard !stopped else { return }
    permission = value
  }
  func requestPermission() async -> Bool {
    guard !stopped, !requestingPermission else { return false }
    requestingPermission = true
    defer { requestingPermission = false }
    let current = generation
    do {
      let value = try await service.requestAuthorization()
      guard !stopped, generation == current else { return false }
      permission = value
      notificationIssue =
        value == .allowed
        ? nil : "Notifications aren't allowed. You can change this in macOS Settings."
      return value == .allowed
    } catch {
      guard !stopped, generation == current else { return false }
      notificationIssue = error.localizedDescription
      return false
    }
  }

  func update(
    settings: FeedbackSettings, events: [HoldHistoryEvent], holds: [Hold], uptime: TimeInterval,
    baseline: Bool = false
  ) {
    guard !stopped else { return }
    let valid = settings.validationMessage == nil ? settings : FeedbackSettings()
    let changed = self.settings != valid
    if changed {
      invalidate()
      self.settings = valid
      nextReminder = nil
    }
    let live = Dictionary(uniqueKeysWithValues: holds.map { ($0.id, $0) })
    if !initialized || baseline {
      initialized = true
      known = live
      resetReminder(uptime)
      return
    }
    let starts = events.filter {
      $0.kind == .started && known[$0.hold.id] == nil && live[$0.hold.id] != nil
        && eligible($0.hold, start: true)
    }
    let ends = events.filter {
      $0.endReason != nil && known[$0.hold.id] != nil
        && (eligible($0.hold, start: false) || (valid.guardStops && isGuard($0.endReason)))
    }
    let extensions = events.filter {
      $0.kind == .extended && known[$0.hold.id] != nil && live[$0.hold.id] != nil
        && ($0.hold.source == .manual || $0.hold.source == .trigger || valid.includeAutomation)
    }
    let wasAwake = !known.isEmpty
    known = live
    if holds.isEmpty {
      if wasAwake { invalidate() }
      nextReminder = nil
    } else if nextReminder == nil || changed {
      resetReminder(uptime)
    }
    if !starts.isEmpty {
      if valid.startSound { play(valid.startChoice) }
      post(.init(kind: .started, title: "Keeping awake", body: description(starts)))
    }
    if !ends.isEmpty {
      if valid.endSound { play(valid.endChoice) }
      post(.init(kind: .ended, title: "Awake hold ended", body: description(ends)))
    }
    if !extensions.isEmpty && valid.extendSound { play(valid.extendChoice) }
  }

  func tick(uptime: TimeInterval) {
    guard !stopped, !known.isEmpty, let deadline = nextReminder, uptime >= deadline else { return }
    resetReminder(uptime)
    post(
      .init(
        kind: .reminder, title: "Still keeping awake",
        body:
          "\(known.count) active reason\(known.count == 1 ? "" : "s"). Open Dilated to review or stop them."
      ))
  }
  func closedLidEnded(_ reason: String, playSound: Bool = true) {
    guard !stopped, settings.guardStops else { return }
    if playSound && settings.endSound { play(settings.endChoice) }
    post(.init(kind: .ended, title: "Closed-lid stopped", body: String(reason.prefix(1000))))
  }
  func preview(_ sound: FeedbackSound) {
    guard !stopped else { return }
    play(sound)
  }
  func testNotification() {
    post(.init(kind: .reminder, title: "Dilated", body: "Notifications are ready."))
  }
  private func eligible(_ hold: Hold, start: Bool) -> Bool {
    if hold.source == .trigger { return start ? settings.triggerStarts : settings.triggerEnds }
    guard hold.source == .manual || settings.includeAutomation else { return false }
    return start ? settings.sessionStarts : settings.sessionEnds
  }
  private func isGuard(_ reason: HoldEndReason?) -> Bool {
    reason == .lowBattery || reason == .lowPowerMode || reason == .helperFailure
  }
  private func description(_ events: [HoldHistoryEvent]) -> String {
    var lines = events.prefix(4).map { event in
      event.hold.label + (event.endReason.map { ": " + $0.title } ?? "")
    }
    if events.count > 4 { lines.append("And \(events.count - 4) more.") }
    return String(lines.joined(separator: "\n").prefix(1000))
  }
  private func resetReminder(_ uptime: TimeInterval) {
    nextReminder =
      settings.notifications && settings.reminderMinutes > 0 && !known.isEmpty
      ? uptime + Double(settings.reminderMinutes * 60) : nil
  }
  private func play(_ sound: FeedbackSound) {
    do {
      try sounds.play(sound)
      soundIssue = nil
    } catch { soundIssue = error.localizedDescription }
  }
  private func post(_ notice: FeedbackNotice) {
    guard !stopped, settings.notifications else { return }
    let kind = notice.kind
    tasks[kind]?.cancel()
    if let previous = requests[kind] { service.cancel([previous]) }
    requests[kind] = notice.id
    let current = generation
    let service = service
    tasks[kind] = Task { [weak self] in
      let permission = await service.authorization()
      guard let self, !self.stopped, self.generation == current, !Task.isCancelled,
        self.requests[kind] == notice.id
      else { return }
      self.permission = permission
      guard permission == .allowed else {
        self.notificationIssue =
          "Notifications aren't allowed. Enable them in Settings when you're ready."
        self.tasks[kind] = nil
        return
      }
      do {
        try await service.send(notice)
        if self.stopped || self.generation != current || self.requests[kind] != notice.id
          || Task.isCancelled
        {
          service.cancel([notice.id])
          return
        }
        self.notificationIssue = nil
      } catch {
        if self.generation == current && self.requests[kind] == notice.id {
          self.notificationIssue = error.localizedDescription
        }
      }
      if self.requests[kind] == notice.id { self.tasks[kind] = nil }
    }
  }
  private func invalidate() {
    generation += 1
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    service.cancel(Array(requests.values))
    requests.removeAll()
    sounds.stop()
  }
  func stop() {
    stopped = true
    invalidate()
    known.removeAll()
    nextReminder = nil
  }
  isolated deinit { stop() }
}
