import AppKit
import DilatedControl
import Foundation
import UserNotifications

private final class ForegroundFeedback: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .list] }
}

@MainActor final class NativeFeedbackService: FeedbackService {
  private var center: UNUserNotificationCenter?
  private let delegate = ForegroundFeedback()
  private func current() -> UNUserNotificationCenter? {
    guard Bundle.main.bundleIdentifier == "com.codeswhat.dilated" else { return nil }
    if let center { return center }
    let center = UNUserNotificationCenter.current()
    center.delegate = delegate
    self.center = center
    return center
  }
  func authorization() async -> FeedbackAuthorization {
    guard let center = current() else { return .unavailable }
    let status = await center.notificationSettings().authorizationStatus
    switch status {
    case .authorized, .provisional: return .allowed
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }
  func requestAuthorization() async throws -> FeedbackAuthorization {
    guard let center = current() else { return .unavailable }
    _ = try await center.requestAuthorization(options: [.alert])
    return await authorization()
  }
  func send(_ notice: FeedbackNotice) async throws {
    guard let center = current() else {
      throw InputError("Open the installed Dilated app to use notifications.")
    }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.threadIdentifier = "dilated." + notice.kind.rawValue
    let request = UNNotificationRequest(
      identifier: notice.id.uuidString, content: content, trigger: nil)
    try await center.add(request)
  }
  func cancel(_ ids: [UUID]) {
    guard let center, !ids.isEmpty else { return }
    center.removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    center.removeDeliveredNotifications(withIdentifiers: ids.map(\.uuidString))
  }
}

@MainActor struct FeedbackSoundStore {
  let directory: URL
  private var folder: URL { directory.appendingPathComponent("sounds", isDirectory: true) }
  func data(for choice: FeedbackSound) throws -> Data {
    let file: URL
    if let id = choice.customID {
      file = folder.appendingPathComponent(id.uuidString + ".sound")
    } else if let resource = choice.resource,
      let url = Bundle.module.url(
        forResource: resource, withExtension: "wav", subdirectory: "Sounds")
    {
      file = url
    } else {
      throw InputError("The sound couldn't be found.")
    }
    return try Self.readInput(file)
  }
  nonisolated static func readInput(_ file: URL) throws -> Data {
    guard file.isFileURL,
      try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        == .typeRegular
    else { throw InputError("Choose a regular audio file.") }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= 2_000_000 {
      try Task.checkCancellation()
      guard let next = try handle.read(upToCount: min(65536, 2_000_001 - data.count)), !next.isEmpty
      else { break }
      data.append(next)
    }
    guard !data.isEmpty, data.count <= 2_000_000 else {
      throw InputError("Choose a sound up to 2 MB.")
    }
    return data
  }
  func save(_ data: Data, name: String) throws -> FeedbackSound {
    guard !data.isEmpty, data.count <= 2_000_000 else {
      throw InputError("Choose a sound up to 2 MB.")
    }
    guard let sound = NSSound(data: data), sound.duration.isFinite,
      (0...10).contains(sound.duration), sound.duration > 0
    else { throw InputError("Choose a supported audio file up to 10 seconds long.") }
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID()
    let file = folder.appendingPathComponent(id.uuidString + ".sound")
    do {
      try data.write(to: file, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    let label = String(name.prefix(200))
    return .custom(id: id, name: label.isEmpty ? "Custom sound" : label)
  }
  func remove(_ id: UUID) throws {
    do {
      try FileManager.default.removeItem(
        at: folder.appendingPathComponent(id.uuidString + ".sound"))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {}
  }
}

@MainActor final class NativeFeedbackSounds: FeedbackSoundPlaying {
  private let store: FeedbackSoundStore
  private var current: NSSound?
  init(directory: URL) { store = FeedbackSoundStore(directory: directory) }
  func play(_ choice: FeedbackSound) throws {
    let data = try store.data(for: choice)
    guard let sound = NSSound(data: data) else {
      throw InputError("The selected sound couldn't be decoded.")
    }
    current?.stop()
    guard sound.play() else { throw InputError("The selected sound couldn't be played.") }
    current = sound
  }
  func stop() {
    current?.stop()
    current = nil
  }
}
