import DilatedControl
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct MASChannelControlServerTests {
  private func stateDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "dilated-control-server-\(UUID().uuidString)")
  }

  #if MAS_CHANNEL
    @Test func startupPathDoesNotCreateAControlServer() throws {
      let directory = stateDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let endpoint = SocketEndpoint(stateDirectory: directory)
      let server = try ApplicationDelegate.makeControlServer(endpoint: endpoint) { _ in
        ControlResponse(ok: true)
      }
      #expect(server == nil)
      #expect(!FileManager.default.fileExists(atPath: endpoint.path))
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  #else
    @Test func directBuildStillCreatesAControlServer() throws {
      let directory = stateDirectory()
      let endpoint = SocketEndpoint(stateDirectory: directory)
      defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: endpoint.directory)
      }
      let server = try ApplicationDelegate.makeControlServer(endpoint: endpoint) { _ in
        ControlResponse(ok: true)
      }
      #expect(server != nil)
      server?.stop()
    }
  #endif
}
