import DilatedCore
import Foundation

@MainActor public protocol HelperTransporting: AnyObject {
  var onDisconnect: (() -> Void)? { get set }
  func send(_ request: HelperRequest) async throws -> HelperReply
  func invalidate()
}

public enum HelperClientError: LocalizedError {
  case disconnected, timedOut, invalidReply, helperUpdate
  case rejected(String)
  public var errorDescription: String? {
    switch self {
    case .disconnected: "The closed-lid helper disconnected. Enable closed-lid again to continue."
    case .timedOut: "The closed-lid helper didn't respond in time. Its safety lease will expire."
    case .invalidReply: "The closed-lid helper returned an invalid reply."
    case .helperUpdate: "The closed-lid helper needs an update. Repair it in Closed Lid settings."
    case .rejected(let message): message
    }
  }
}

@MainActor public final class HelperTransport: HelperTransporting {
  public var onDisconnect: (() -> Void)?
  private let serviceName: String
  private var connection: NSXPCConnection?
  private var generation = UUID()
  private struct Pending {
    let continuation: CheckedContinuation<HelperReply, any Error>
    var deadline: Task<Void, Never>?
  }
  private var pending: [UUID: Pending] = [:]

  public init() { serviceName = HelperIdentity.serviceID }
  init(serviceName: String) { self.serviceName = serviceName }

  public func send(_ request: HelperRequest) async throws -> HelperReply {
    let payload = try JSONEncoder().encode(request)
    guard payload.count <= HelperIdentity.maximumMessageBytes else {
      throw HelperClientError.rejected("The helper request is too large.")
    }
    let connection = connect()
    let current = generation
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = Pending(continuation: continuation)
      pending[id]?.deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(8)) } catch { return }
        self?.breakConnection(current, error: HelperClientError.timedOut)
      }
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
          Task { @MainActor [weak self] in self?.breakConnection(current, error: error) }
        } as? any HelperXPCProtocol
      guard let proxy else {
        breakConnection(current, error: HelperClientError.disconnected)
        return
      }
      proxy.perform(payload) { [weak self] data in
        Task { @MainActor [weak self] in self?.receive(data, id: id, generation: current) }
      }
    }
  }

  public func invalidate() { close(error: HelperClientError.disconnected, notify: false) }

  private func connect() -> NSXPCConnection {
    if let connection { return connection }
    let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
    connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
    let current = generation
    connection.interruptionHandler = { @Sendable [weak self] in
      Task { @MainActor [weak self] in
        self?.breakConnection(current, error: HelperClientError.disconnected)
      }
    }
    connection.invalidationHandler = { @Sendable [weak self] in
      Task { @MainActor [weak self] in
        self?.breakConnection(current, error: HelperClientError.disconnected)
      }
    }
    self.connection = connection
    connection.activate()
    return connection
  }

  private func receive(_ data: Data, id: UUID, generation current: UUID) {
    guard current == generation, let request = pending.removeValue(forKey: id) else { return }
    request.deadline?.cancel()
    guard data.count <= HelperIdentity.maximumMessageBytes,
      let response = try? JSONDecoder().decode(HelperReply.self, from: data)
    else {
      request.continuation.resume(throwing: HelperClientError.invalidReply)
      close(error: HelperClientError.invalidReply, notify: true)
      return
    }
    request.continuation.resume(returning: response)
  }

  private func breakConnection(_ current: UUID, error: any Error) {
    guard current == generation else { return }
    close(error: error, notify: true)
  }

  private func close(error: any Error, notify: Bool) {
    let old = connection
    connection = nil
    generation = UUID()
    let waiting = pending
    pending.removeAll()
    old?.invalidate()
    for request in waiting.values {
      request.deadline?.cancel()
      request.continuation.resume(throwing: error)
    }
    if notify { onDisconnect?() }
  }
}
