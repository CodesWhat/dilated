import CryptoKit
import Darwin
import Foundation

public struct SocketEndpoint: Sendable {
  public let stateDirectory: URL
  public var directory: URL {
    let digest = SHA256.hash(data: Data(stateDirectory.standardizedFileURL.path.utf8)).prefix(8).map
    { String(format: "%02x", $0) }.joined()
    return URL(fileURLWithPath: "/tmp/com.codeswhat.dilated-\(getuid())-\(digest)")
  }
  public var path: String { directory.appendingPathComponent("control.sock").path }
  public init(stateDirectory: URL) { self.stateDirectory = stateDirectory }
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
      try files.createDirectory(
        at: endpoint.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch {
      var facts = stat()
      guard lstat(endpoint.directory.path, &facts) == 0, facts.st_uid == getuid(),
        (facts.st_mode & S_IFMT) == S_IFDIR, (facts.st_mode & 0o777) == 0o700
      else {
        close(fd)
        close(lockFD)
        throw InputError("Control directory must be owned by this user with permissions 0700.")
      }
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
  public static func send(_ request: ControlRequest, to endpoint: SocketEndpoint) throws
    -> ControlResponse
  {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw socketError("Create control connection") }
    defer { close(fd) }
    let powerOperation = [.stopAll, .release, .toggle].contains(request.action)
    let helperOperation = [.helperSetup, .helperRemove, .prepareUpdate, .prepareUninstall].contains(
      request.action)
    configure(
      fd, receiveSeconds: helperOperation ? 60 : request.closedLid ? 20 : powerOperation ? 10 : 3)
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
    try writeLine(WireJSON.encode(request), to: fd)
    return try WireJSON.decode(ControlResponse.self, from: readLine(fd))
  }
}
