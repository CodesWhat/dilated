import Darwin
import DilatedCore
import Foundation

@main struct HelperMain {
  static func main() throws {
    if CommandLine.arguments == [CommandLine.arguments[0], "--inspect"] {
      let probe = HelperProbe(
        protocolVersion: HelperIdentity.protocolVersion,
        buildIdentity: try HelperCodeIdentity.current(),
        effectiveUID: geteuid(), readback: NativeClosedLidPower.readback(),
        environment: NativeClosedLidPower.environment())
      FileHandle.standardOutput.write(try JSONEncoder().encode(probe))
      return
    }
    guard CommandLine.arguments.count == 1, geteuid() == 0 else {
      FileHandle.standardError.write(
        Data("Run the helper through the approved Dilated app.\n".utf8))
      exit(1)
    }
    let origin = ContinuousClock.now
    let service = ClosedLidService(
      power: SerialPowerDriver(), environment: NativeClosedLidPower.environment,
      clock: {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      }, buildIdentity: try HelperCodeIdentity.current())
    let runtime = HelperRuntime(service: service)
    runtime.start()
    withExtendedLifetime(runtime) { dispatchMain() }
  }
}

private struct HelperProbe: Encodable {
  let protocolVersion: Int
  let buildIdentity: String
  let effectiveUID: uid_t
  let readback: ClosedLidReadback
  let environment: ClosedLidEnvironment
}

private final class HelperRuntime: NSObject, NSXPCListenerDelegate {
  private let service: ClosedLidService
  private let listener: NSXPCListener

  init(service: ClosedLidService) {
    self.service = service
    listener = NSXPCListener(machServiceName: HelperIdentity.serviceID)
    super.init()
    listener.setConnectionCodeSigningRequirement(HelperIdentity.appRequirement)
    listener.delegate = self
  }

  func start() {
    let service = service
    Task {
      await service.start()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
        await service.tick()
      }
    }
    listener.activate()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    let owner = UUID()
    let service = service
    connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
    connection.exportedObject = HelperSession(service: service, owner: owner)
    connection.invalidationHandler = { Task { await service.disconnected(owner: owner) } }
    connection.interruptionHandler = { Task { await service.disconnected(owner: owner) } }
    connection.activate()
    return true
  }
}

private final class HelperSession: NSObject, HelperXPCProtocol, @unchecked Sendable {
  private let service: ClosedLidService
  private let owner: UUID
  init(service: ClosedLidService, owner: UUID) {
    self.service = service
    self.owner = owner
  }
  func perform(_ payload: Data, reply: @escaping @Sendable (Data) -> Void) {
    let service = service
    let owner = owner
    Task { reply(await service.handlePayload(payload, owner: owner)) }
  }
}
