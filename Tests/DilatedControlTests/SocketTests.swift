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
    #expect(throws: (any Error).self) {
      try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
    }
  }
}
