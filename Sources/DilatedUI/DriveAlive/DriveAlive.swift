import Darwin
import Foundation

public struct DriveAliveVolume: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  var isValid: Bool {
    !id.isEmpty && id.utf8.count <= 4096 && !name.isEmpty && name.count <= 255
      && path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 4096
  }
}

public struct DriveAliveSettings: Codable, Equatable, Sendable {
  public var enabled = false
  public var intervalSeconds = 60
  public var onlyWhileAwake = true
  public var volumes: [DriveAliveVolume] = []
  public init() {}
  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    intervalSeconds =
      try values.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? intervalSeconds
    onlyWhileAwake =
      try values.decodeIfPresent(Bool.self, forKey: .onlyWhileAwake) ?? onlyWhileAwake
    volumes = try values.decodeIfPresent([DriveAliveVolume].self, forKey: .volumes) ?? volumes
  }

  var validationMessage: String? {
    guard (30...3600).contains(intervalSeconds) else {
      return "Choose a Drive Alive interval from 30 seconds to 1 hour."
    }
    guard volumes.count <= 20, volumes.allSatisfy(\.isValid),
      Set(volumes.map(\.id)).count == volumes.count
    else { return "Choose up to 20 distinct mounted volumes." }
    return nil
  }
}

struct DriveAliveError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

struct MountedDrive: Sendable {
  let volume: DriveAliveVolume
  let readOnly: Bool
  let device0: Int32
  let device1: Int32
}

enum NativeDriveAlive {
  static func mounted() throws -> [MountedDrive] {
    let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsReadOnlyKey]
    guard
      let urls = FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys), options: [])
    else { throw DriveAliveError("Couldn't read mounted volumes.") }
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0, count <= 4096 else {
      throw DriveAliveError("Couldn't read the mounted filesystem table.")
    }
    var table: [statfs] = Array(repeating: statfs(), count: Int(count) + 8)
    let capacity = Int32(table.count * MemoryLayout<statfs>.stride)
    let written = getfsstat(&table, capacity, MNT_NOWAIT)
    guard written >= 0 else { throw DriveAliveWriter.systemError() }
    var mounts: [String: statfs] = [:]
    for info in table.prefix(Int(written)) {
      let path = withUnsafeBytes(of: info.f_mntonname) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      mounts[path] = info
    }
    return urls.compactMap { url -> MountedDrive? in
      guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
      guard let info = mounts[url.resolvingSymlinksInPath().path] else { return nil }
      let source = withUnsafeBytes(of: info.f_mntfromname) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      let type = withUnsafeBytes(of: info.f_fstypename) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      let identity =
        values.volumeUUIDString.map { "uuid:" + $0 }
        ?? "mount:" + type + ":" + source
      let volume = DriveAliveVolume(
        id: identity, name: values.volumeName ?? url.lastPathComponent,
        path: url.resolvingSymlinksInPath().path)
      guard volume.isValid else { return nil }
      return MountedDrive(
        volume: volume,
        readOnly: values.volumeIsReadOnly == true || info.f_flags & UInt32(MNT_RDONLY) != 0,
        device0: info.f_fsid.val.0, device1: info.f_fsid.val.1)
    }.sorted { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
  }

  static func pulse(_ selected: DriveAliveVolume) async throws {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let matches = try mounted().filter { $0.volume.id == selected.id }
      guard matches.count == 1, let current = matches.first else {
        throw DriveAliveError("This volume isn't mounted, or its identity is ambiguous.")
      }
      guard !current.readOnly else { throw DriveAliveError("This volume is read-only.") }
      let url = URL(fileURLWithPath: current.volume.path, isDirectory: true)
      try DriveAliveWriter.write(in: url, name: ".dilated-drive-alive-" + UUID().uuidString) {
        descriptor in
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw DriveAliveWriter.systemError() }
        let mount = withUnsafeBytes(of: info.f_mntonname) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard info.f_fsid.val.0 == current.device0, info.f_fsid.val.1 == current.device1,
          URL(fileURLWithPath: mount).resolvingSymlinksInPath().path == current.volume.path
        else {
          throw DriveAliveError("The selected volume was removed or changed before the write.")
        }
        guard info.f_flags & UInt32(MNT_RDONLY) == 0 else {
          throw DriveAliveError("This volume is read-only.")
        }
        try Task.checkCancellation()
      }
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

enum DriveAliveWriter {
  static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

  static func write(in directory: URL, name: String, validate: (Int32) throws -> Void) throws {
    guard directory.isFileURL, name.hasPrefix(".dilated-drive-alive-"),
      !name.contains("/"), name.utf8.count <= 255, !name.utf8.contains(0)
    else { throw DriveAliveError("Invalid Drive Alive file location.") }
    try Task.checkCancellation()
    let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw systemError() }
    defer { close(root) }
    try validate(root)
    try Task.checkCancellation()
    let file = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw systemError() }
    var removed = false
    defer {
      close(file)
      if !removed { _ = unlinkat(root, name, 0) }
    }
    var value = ProcessInfo.processInfo.systemUptime.bitPattern.littleEndian
    try withUnsafeBytes(of: &value) { bytes in
      var offset = 0
      while offset < bytes.count {
        try Task.checkCancellation()
        let result = Darwin.write(
          file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw systemError() }
        offset += result
      }
    }
    while fsync(file) != 0 {
      if errno != EINTR { throw systemError() }
      try Task.checkCancellation()
    }
    guard unlinkat(root, name, 0) == 0 else { throw systemError() }
    removed = true
  }
}
