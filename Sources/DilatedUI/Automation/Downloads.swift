import CoreServices
import DilatedControl
import Foundation

struct DownloadTarget: Sendable {
  enum Mode: Sendable { case file, folder }
  let url: URL
  let mode: Mode
  var watchedURL: URL { mode == .folder ? url : url.deletingLastPathComponent() }
}

struct DownloadFileState: Equatable, Sendable {
  var size: UInt64
  let modified: Date
  let device: UInt64
  let inode: UInt64
}

struct DownloadSnapshot: Equatable, Sendable {
  var files: [String: DownloadFileState]
}

enum NativeDownloadScanner {
  private static let extensions: Set<String> = ["crdownload", "part", "download", "partial"]

  static func isMissing(_ error: any Error) -> Bool {
    guard let error = error as? CocoaError else { return false }
    return error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
  }

  static func read(_ target: DownloadTarget, maximumEntries: Int = 10000) throws -> DownloadSnapshot
  {
    let manager = FileManager.default
    var files: [String: DownloadFileState] = [:]
    var visited = 0
    func inspect(_ url: URL, descend: Bool) throws {
      try Task.checkCancellation()
      visited += 1
      guard visited <= maximumEntries else {
        throw InputError("This folder has too many entries. Choose an individual download instead.")
      }
      let attributes = try manager.attributesOfItem(atPath: url.path)
      let type = attributes[.type] as? FileAttributeType
      guard type == .typeRegular || type == .typeDirectory else {
        throw InputError("Choose a regular file or download folder, without symbolic links.")
      }
      guard let modified = attributes[.modificationDate] as? Date,
        let device = attributes[.systemNumber] as? NSNumber,
        let inode = attributes[.systemFileNumber] as? NSNumber,
        let size = attributes[.size] as? NSNumber
      else { throw InputError("Couldn't read download activity.") }
      files[url.path] = .init(
        size: type == .typeRegular ? size.uint64Value : 0, modified: modified,
        device: device.uint64Value, inode: inode.uint64Value)
      if type == .typeDirectory && descend {
        for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
          do { try inspect(child, descend: true) } catch {
            if !isMissing(error) { throw error }
          }
        }
      }
    }
    if target.mode == .file {
      let type = try manager.attributesOfItem(atPath: target.url.path)[.type] as? FileAttributeType
      guard
        type == .typeRegular
          || (type == .typeDirectory && extensions.contains(target.url.pathExtension.lowercased()))
      else { throw InputError("Choose a file or a browser's partial download package.") }
      try inspect(target.url, descend: true)
    } else {
      let type = try manager.attributesOfItem(atPath: target.url.path)[.type] as? FileAttributeType
      guard type == .typeDirectory else {
        throw InputError("The selected download folder is unavailable.")
      }
      for child in try manager.contentsOfDirectory(at: target.url, includingPropertiesForKeys: nil)
      {
        try Task.checkCancellation()
        visited += 1
        guard visited <= maximumEntries else {
          throw InputError(
            "This folder has too many entries. Choose an individual download instead.")
        }
        if extensions.contains(child.pathExtension.lowercased()) {
          do { try inspect(child, descend: true) } catch {
            if !isMissing(error) { throw error }
          }
        }
      }
    }
    return .init(files: files)
  }

  static func readInBackground(_ target: DownloadTarget) async throws -> DownloadSnapshot {
    let task = Task.detached(priority: .utility) { try read(target) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

private final class DownloadEventTarget: Sendable {
  let changed: @MainActor @Sendable () -> Void
  init(_ changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
  func signal() { Task { @MainActor [changed] in changed() } }
}

@MainActor enum NativeDownloadEvents {
  static func subscribe(_ url: URL, changed: @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)?
  {
    let target = DownloadEventTarget(changed)
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(target).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        | kFSEventStreamCreateFlagFileEvents)
    guard
      let stream = FSEventStreamCreate(
        nil,
        { _, info, _, _, _, _ in
          guard let info else { return }
          Unmanaged<DownloadEventTarget>.fromOpaque(info).takeUnretainedValue().signal()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.5, flags)
    else { return nil }
    FSEventStreamSetDispatchQueue(stream, .main)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    return { [target] in
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      withExtendedLifetime(target) {}
    }
  }
}

@MainActor final class DownloadMonitor {
  typealias Reader = @MainActor (DownloadTarget) async throws -> DownloadSnapshot
  typealias Subscription =
    @MainActor (URL, @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)?
  private let target: DownloadTarget
  private let quietSeconds: TimeInterval
  private let read: Reader
  private let subscribe: Subscription
  private let clock: @MainActor () -> TimeInterval
  private let finished: @MainActor (String?) -> Void
  private var cancelSubscription: (@MainActor () -> Void)?
  private var readTask: Task<Void, Never>?
  private var snapshot: DownloadSnapshot?
  private var quietDeadline: TimeInterval?
  private var needsRefresh = false
  private var generation = 0
  private var active = false

  init(
    target: DownloadTarget, quietSeconds: TimeInterval,
    read: @escaping Reader = NativeDownloadScanner.readInBackground,
    subscribe: @escaping Subscription = NativeDownloadEvents.subscribe,
    clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    finished: @escaping @MainActor (String?) -> Void
  ) {
    self.target = target
    self.quietSeconds = quietSeconds
    self.read = read
    self.subscribe = subscribe
    self.clock = clock
    self.finished = finished
  }

  func start() throws {
    guard !active else { return }
    guard quietSeconds.isFinite, (5...3600).contains(quietSeconds) else {
      throw InputError("Choose an inactivity interval from 5 seconds to 1 hour.")
    }
    active = true
    guard let cancel = subscribe(target.watchedURL, { [weak self] in self?.requestRefresh() })
    else {
      active = false
      throw InputError("Couldn't watch this download. Choose a local file or folder you can read.")
    }
    cancelSubscription = cancel
    requestRefresh()
  }

  func tick() {
    guard active, let quietDeadline, clock() >= quietDeadline, readTask == nil else { return }
    requestRefresh()
  }

  func stop() {
    active = false
    generation += 1
    readTask?.cancel()
    readTask = nil
    needsRefresh = false
    cancelSubscription?()
    cancelSubscription = nil
  }

  private func requestRefresh() {
    guard active else { return }
    guard readTask == nil else {
      needsRefresh = true
      return
    }
    let current = generation
    let read = read
    let target = target
    readTask = Task { [weak self] in
      let result: Result<DownloadSnapshot, any Error>
      do { result = .success(try await read(target)) } catch { result = .failure(error) }
      guard let self, self.active, self.generation == current else { return }
      self.readTask = nil
      switch result {
      case .failure(let error):
        if self.snapshot != nil && target.mode == .file && NativeDownloadScanner.isMissing(error) {
          self.end(nil)
        } else {
          self.end("Download watch ended: \(error.localizedDescription)")
        }
      case .success(let next):
        if next.files.isEmpty {
          if !self.needsRefresh {
            self.end(self.snapshot == nil ? "No partial downloads were found in that folder." : nil)
          }
        } else if self.snapshot != next {
          self.snapshot = next
          self.quietDeadline = self.clock() + self.quietSeconds
        } else if !self.needsRefresh && self.quietDeadline.map({ self.clock() >= $0 }) == true {
          self.end(nil)
        }
      }
      if self.needsRefresh {
        self.needsRefresh = false
        self.requestRefresh()
      }
    }
  }

  private func end(_ issue: String?) {
    stop()
    finished(issue)
  }

  isolated deinit { stop() }
}
