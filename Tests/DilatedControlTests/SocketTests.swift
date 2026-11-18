import Darwin
import Foundation
import Testing

@testable import DilatedControl

struct SocketTests {
  @Test func liveSocketRoundTripAndSingleInstanceLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let server = try LocalSocketServer(endpoint: endpoint) { request in
      ControlResponse(ok: request.action == .status, message: "Live response")
    }
    defer { server.stop() }
    let response = try await Task.detached {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }.value
    #expect(response.ok)
    #expect(response.message == "Live response")
    #expect(throws: (any Error).self) {
      try LocalSocketServer(endpoint: endpoint) { _ in ControlResponse(ok: true) }
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }
  @Test func unreachableSocketReportsFailure() {
    let endpoint = SocketEndpoint(stateDirectory: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"))
    #expect(throws: AppConnectionUnavailable.self) {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }
  }
  @Test func aPowerOperationCanFinishBeforeTheControlClientDeadline() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let server = try LocalSocketServer(endpoint: endpoint) { _ in
      try? await Task.sleep(for: .milliseconds(3300))
      return ControlResponse(ok: true)
    }
    defer { server.stop() }
    let response = try await Task.detached {
      try LocalSocketClient.send(ControlRequest(action: .stopAll), to: endpoint)
    }.value
    #expect(response.ok)
  }

  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  @Test func theEndpointLivesUnderThePerUserTemporaryDirectoryAndFitsSockaddr() {
    let endpoint = SocketEndpoint(stateDirectory: scratch())
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0)
    let base = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    #expect(endpoint.path.hasPrefix(base))
    #expect(!endpoint.path.hasPrefix("/tmp/"))
    #expect(endpoint.path.utf8.count + 1 <= SocketEndpoint.maxPathBytes)
  }

  @Test func aLongRuntimeDirectoryFallsBackToAShorterName() {
    let base = URL(
      fileURLWithPath: "/private/var/folders/" + String(repeating: "x", count: 40) + "/T")
    let endpoint = SocketEndpoint(stateDirectory: scratch(), runtimeDirectory: base)
    #expect(endpoint.path.utf8.count + 1 <= SocketEndpoint.maxPathBytes)
    #expect(endpoint.directory.lastPathComponent.count < "com.codeswhat.dilated-".count + 16)
  }

  @Test func aDirectoryWithLoosePermissionsIsRefusedByServerAndClient() throws {
    let state = scratch()
    let runtime = scratch()
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: state)
      try? FileManager.default.removeItem(at: runtime)
    }
    let endpoint = SocketEndpoint(stateDirectory: state, runtimeDirectory: runtime)
    try FileManager.default.createDirectory(
      at: endpoint.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755])
    chmod(endpoint.directory.path, 0o755)
    #expect(throws: InputError.self) {
      try LocalSocketServer(endpoint: endpoint) { _ in ControlResponse(ok: true) }
    }
    #expect(throws: InputError.self) {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }
  }

  @Test func aSymlinkedOrForeignDirectoryFailsValidation() throws {
    let root = scratch()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(
      at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    chmod(real.path, 0o700)
    try SocketEndpoint.validateDirectory(real)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(throws: InputError.self) { try SocketEndpoint.validateDirectory(link) }
    #expect(throws: InputError.self) {
      try SocketEndpoint.validateDirectory(real, uid: getuid() &+ 1)
    }
    #expect(throws: InputError.self) {
      try SocketEndpoint.validateDirectory(root.appendingPathComponent("missing"))
    }
  }

  @Test func aPeerRunningAsAnotherUserIsRejectedBeforeAnythingIsSent() throws {
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { for descriptor in pair { close(descriptor) } }
    try LocalSocketClient.requirePeer(pair[0])
    #expect(throws: InputError.self) {
      try LocalSocketClient.requirePeer(pair[0], uid: getuid() &+ 1)
    }
  }

  @Test func aStaleEndpointFromACrashedAppIsRecovered() async throws {
    let state = scratch()
    let runtime = scratch()
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: state)
      try? FileManager.default.removeItem(at: runtime)
    }
    let endpoint = SocketEndpoint(stateDirectory: state, runtimeDirectory: runtime)
    try FileManager.default.createDirectory(
      at: endpoint.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    chmod(endpoint.directory.path, 0o700)
    FileManager.default.createFile(atPath: endpoint.path, contents: Data("stale".utf8))
    #expect(throws: AppConnectionUnavailable.self) {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }
    let server = try LocalSocketServer(endpoint: endpoint) { _ in
      ControlResponse(ok: true, message: "recovered")
    }
    defer { server.stop() }
    let response = try await Task.detached {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }.value
    #expect(response.message == "recovered")
  }

  @Test func stoppingTheServerRemovesItsEndpointAndAllowsARestart() async throws {
    let state = scratch()
    defer { try? FileManager.default.removeItem(at: state) }
    let endpoint = SocketEndpoint(stateDirectory: state)
    let first = try LocalSocketServer(endpoint: endpoint) { _ in ControlResponse(ok: true) }
    first.stop()
    #expect(!FileManager.default.fileExists(atPath: endpoint.path))
    let second = try LocalSocketServer(endpoint: endpoint) { _ in ControlResponse(ok: true) }
    defer { second.stop() }
    let response = try await Task.detached {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }.value
    #expect(response.ok)
  }
}
