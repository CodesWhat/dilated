import CryptoKit
import Darwin
import Foundation

public struct SocketEndpoint: Sendable {
  public let stateDirectory: URL
  /// Parent of the 0700 socket directory. Defaults to the per-user Darwin temp directory, which
  /// no other account can write to, so the endpoint can't be pre-created by someone else.
  public let runtimeDirectory: URL
  static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

  public var directory: URL { Self.layout(state: stateDirectory, base: runtimeDirectory).directory }
  public var path: String { Self.layout(state: stateDirectory, base: runtimeDirectory).path }
  public init(stateDirectory: URL, runtimeDirectory: URL? = nil) {
    self.stateDirectory = stateDirectory
    self.runtimeDirectory = runtimeDirectory ?? Self.userTemporaryDirectory()
  }

  /// The longest layout that fits in `sockaddr_un`, falling back to shorter hashed names.
  private static func layout(state: URL, base: URL) -> (directory: URL, path: String) {
    let digest = SHA256.hash(data: Data(state.standardizedFileURL.path.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let candidates = [
      ("com.codeswhat.dilated-\(digest.prefix(16))", "control.sock"),
      ("dilated-\(digest.prefix(12))", "control.sock"),
      ("d-\(digest.prefix(8))", "c.sock"),
    ]
    var fallback: (URL, String)?
    for (folder, file) in candidates {
      let directory = base.appendingPathComponent(folder, isDirectory: true)
      let path = directory.appendingPathComponent(file).path
      fallback = (directory, path)
      if path.utf8.count + 1 <= maxPathBytes { return (directory, path) }
    }
    return fallback!
  }

  private static func userTemporaryDirectory() -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
      return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  }

  /// The socket directory must be a real directory (not a symlink) owned by `uid` with mode 0700.
  static func validateDirectory(_ directory: URL, uid: uid_t = getuid()) throws {
    var facts = stat()
    guard lstat(directory.path, &facts) == 0, facts.st_uid == uid,
      (facts.st_mode & S_IFMT) == S_IFDIR, (facts.st_mode & 0o7777) == 0o700
    else {
      throw InputError("Control directory must be owned by this user with permissions 0700.")
    }
  }

  public static var current: SocketEndpoint {
    let configured = ProcessInfo.processInfo.environment["DILATED_STATE_DIR"]
    let directory =
      configured.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dilated")
    return SocketEndpoint(stateDirectory: directory)
  }
}

public enum WireJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(type, from: data)
  }
}

private func socketError(_ operation: String) -> NSError {
  NSError(
    domain: NSPOSIXErrorDomain, code: Int(errno),
    userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
}

private func address(for endpoint: SocketEndpoint) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(endpoint.path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
    throw InputError("Control socket path is too long.")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return address
}

private func configure(_ fd: Int32, receiveSeconds: Int = 3) {
  var enabled: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
  var receive = timeval(tv_sec: receiveSeconds, tv_usec: 0)
  var send = timeval(tv_sec: 3, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout.size(ofValue: receive)))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout.size(ofValue: send)))
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

private func readLine(_ fd: Int32) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while data.count <= 65536 {
    let count = recv(fd, &buffer, buffer.count, 0)
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { throw socketError("Read control response") }
    data.append(contentsOf: buffer.prefix(count))
    if let end = data.firstIndex(of: 10) {
      guard end <= 65536 else { throw InputError("Control message exceeds 64 KiB.") }
      return data.prefix(upTo: end)
    }
  }
  throw InputError("Control message exceeds 64 KiB.")
}

private func writeLine(_ data: Data, to fd: Int32) throws {
  var line = data
  line.append(10)
  try line.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw socketError("Write control request") }
      offset += count
    }
  }
}

public final class LocalSocketServer: @unchecked Sendable {
  private let source: DispatchSourceRead
  private let queue = DispatchQueue(label: "com.codeswhat.dilated.control")
  private let stopped = DispatchGroup()

  public init(
    endpoint: SocketEndpoint, handler: @escaping @Sendable (ControlRequest) async -> ControlResponse
  ) throws {
    let files = FileManager.default
    try files.createDirectory(
      at: endpoint.stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let lockPath = endpoint.stateDirectory.appendingPathComponent("app.lock").path
    let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { throw socketError("Open app lock") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      close(lockFD)
      throw InputError("Dilated is already running for this state directory.")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      close(lockFD)
      throw socketError("Create control socket")
    }
    do {
      if mkdir(endpoint.directory.path, 0o700) != 0 && errno != EEXIST {
        throw socketError("Create control directory")
      }
      try SocketEndpoint.validateDirectory(endpoint.directory)
    } catch {
      close(fd)
      close(lockFD)
      throw error
    }
    do {
      var addr = try address(for: endpoint)
      unlink(endpoint.path)
      let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard result == 0, chmod(endpoint.path, 0o600) == 0, listen(fd, 16) == 0 else {
        throw socketError("Listen on control socket")
      }
    } catch {
      close(fd)
      close(lockFD)
      unlink(endpoint.path)
      throw error
    }
    configure(fd)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    stopped.enter()
    let stopped = self.stopped
    source.setCancelHandler {
      close(fd)
      unlink(endpoint.path)
      try? files.removeItem(at: endpoint.directory)
      close(lockFD)
      stopped.leave()
    }
    source.setEventHandler {
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { break }
        configure(client)
        _ = fcntl(client, F_SETFL, 0)
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let request = try WireJSON.decode(ControlRequest.self, from: readLine(client))
            Task.detached {
              defer { close(client) }
              let response = await handler(request)
              try? writeLine(WireJSON.encode(response), to: client)
            }
          } catch {
            try? writeLine(
              WireJSON.encode(
                ControlResponse(
                  ok: false, message: error.localizedDescription, code: "invalidRequest")),
              to: client)
            close(client)
          }
        }
      }
    }
    source.resume()
  }

  public func stop() {
    source.cancel()
    _ = stopped.wait(timeout: .now() + 3)
  }
  deinit { source.cancel() }
}

public struct AppConnectionUnavailable: LocalizedError {
  public let text: String
  public var errorDescription: String? { text }
}

public enum LocalSocketClient {
  /// Long enough for the admin password dialog; status keeps the short timeout.
  public static let adminPromptSeconds = 300

  public static func usesAdminPrompt(_ action: ControlAction) -> Bool {
    [.lidPermissionInstall, .lidPermissionRemove, .helperSetup, .helperRemove].contains(action)
  }

  /// `prepare-uninstall --remove-lid-permission` shows the same password dialog.
  public static func usesAdminPrompt(_ request: ControlRequest) -> Bool {
    usesAdminPrompt(request.action)
      || (request.action == .prepareUninstall && request.removeLidPermission)
  }

  public static func send(_ request: ControlRequest, to endpoint: SocketEndpoint) throws
    -> ControlResponse
  {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw socketError("Create control connection") }
    defer { close(fd) }
    let powerOperation = [.stopAll, .release, .toggle].contains(request.action)
    let helperOperation = [.helperSetup, .helperRemove, .prepareUpdate, .prepareUninstall].contains(
      request.action)
    let adminPrompt = Self.usesAdminPrompt(request)
    configure(
      fd,
      receiveSeconds: adminPrompt
        ? Self.adminPromptSeconds
        : helperOperation ? 60 : request.closedLid ? 20 : powerOperation ? 10 : 3)
    var facts = stat()
    guard lstat(endpoint.directory.path, &facts) == 0 else {
      throw AppConnectionUnavailable(text: "Connect to Dilated. Start the app first")
    }
    try SocketEndpoint.validateDirectory(endpoint.directory)
    var addr = try address(for: endpoint)
    let result = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      throw AppConnectionUnavailable(
        text: socketError("Connect to Dilated. Start the app first").localizedDescription)
    }
    try requirePeer(fd)
    try writeLine(WireJSON.encode(request), to: fd)
    return try WireJSON.decode(ControlResponse.self, from: readLine(fd))
  }

  /// Refuses to send anything to a listener that isn't running as this user.
  static func requirePeer(_ fd: Int32, uid: uid_t = getuid()) throws {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid else {
      throw InputError("The control socket isn't owned by this user. Refusing to send.")
    }
  }
}
