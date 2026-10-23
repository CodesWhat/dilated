import DilatedCore
import Foundation
import Observation

@MainActor @Observable public final class ClosedLidController {
  public private(set) var state: HelperState?
  public private(set) var lastError: String?
  public private(set) var pendingEnable = false
  public private(set) var busy = false
  @ObservationIgnored public var onEnded: ((String) -> Void)?
  @ObservationIgnored public var onChange: (() -> Void)?
  @ObservationIgnored private let transport: any HelperTransporting
  @ObservationIgnored private let expectedBuild: () throws -> String
  @ObservationIgnored private var leaseID: UUID?
  @ObservationIgnored private var leaseGeneration: UUID?
  @ObservationIgnored private var monitoring: Task<Void, Never>?
  @ObservationIgnored private var operation = UUID()
  public var active: Bool { leaseID != nil && state?.enabled == true }

  public init(
    transport: any HelperTransporting = HelperTransport(),
    expectedBuild: @escaping () throws -> String = {
      try HelperCodeIdentity.executable(
        at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated-helper"))
    }
  ) {
    self.transport = transport
    self.expectedBuild = expectedBuild
    transport.onDisconnect = { [weak self] in self?.lostConnection() }
  }

  public func refresh() async throws {
    do {
      _ = try await send(.init(action: .status))
      lastError = nil
    } catch {
      if error is CancellationError { throw error }
      failed(error)
      throw error
    }
  }

  public func enable(policy: ClosedLidPolicy) async throws {
    guard !busy, leaseID == nil else {
      throw HelperClientError.rejected("Closed-lid is already active or changing.")
    }
    busy = true
    pendingEnable = true
    let current = UUID()
    operation = current
    defer {
      if operation == current {
        busy = false
        pendingEnable = false
        onChange?()
      }
    }
    do {
      let before = try await send(.init(action: .status))
      guard before.ready, before.phase == .off else {
        throw HelperClientError.rejected(before.message ?? "The helper isn't ready to enable.")
      }
      let enabled = try await send(.init(action: .enable, policy: policy))
      guard enabled.enabled, let id = enabled.leaseID else { throw HelperClientError.invalidReply }
      leaseID = id
      leaseGeneration = enabled.generation
      lastError = nil
      startMonitoring()
    } catch {
      guard operation == current else { throw CancellationError() }
      failed(error)
      throw error
    }
  }

  public func disable() async throws { try await end(sleep: false) }
  public func sleepNow() async throws { try await end(sleep: true) }

  public func heartbeat() async throws {
    guard let leaseID else {
      throw HelperClientError.rejected("Enable closed-lid again to continue.")
    }
    do {
      _ = try await send(.init(action: .heartbeat, leaseID: leaseID))
    } catch {
      if error is CancellationError { throw error }
      failed(error)
      throw error
    }
  }

  public func invalidate() {
    operation = UUID()
    busy = false
    pendingEnable = false
    monitoring?.cancel()
    monitoring = nil
    leaseID = nil
    leaseGeneration = nil
    transport.invalidate()
  }

  private func end(sleep: Bool) async throws {
    let current = UUID()
    operation = current
    let id = leaseID
    leaseID = nil
    leaseGeneration = nil
    pendingEnable = false
    monitoring?.cancel()
    monitoring = nil
    busy = true
    defer {
      if operation == current {
        busy = false
        onChange?()
      }
    }
    do {
      let result = try await send(
        .init(action: sleep ? .sleep : .disable, leaseID: id), checkBuild: false)
      guard result.readback.confirmedDisabled, result.leaseID == nil, result.phase == .off else {
        throw HelperClientError.rejected(
          result.message ?? "macOS hasn't confirmed closed-lid is off.")
      }
      lastError = nil
    } catch {
      guard operation == current else { throw CancellationError() }
      failed(error)
      throw error
    }
  }

  private func send(_ request: HelperRequest, checkBuild: Bool = true) async throws -> HelperState {
    let current = operation
    let reply = try await transport.send(request)
    guard operation == current else { throw CancellationError() }
    guard let value = reply.state, value.protocolVersion == HelperIdentity.protocolVersion else {
      throw HelperClientError.invalidReply
    }
    observe(value)
    guard reply.ok else {
      throw HelperClientError.rejected(
        reply.message ?? value.message ?? "The helper refused the request.")
    }
    if checkBuild, try value.buildIdentity != expectedBuild() {
      throw HelperClientError.helperUpdate
    }
    return value
  }

  private func observe(_ value: HelperState) {
    state = value
    if let leaseID, value.leaseID != leaseID || value.generation != leaseGeneration {
      self.leaseID = nil
      leaseGeneration = nil
      monitoring?.cancel()
      monitoring = nil
      onEnded?(
        value.stopReason?.localizedDescription ?? "Closed-lid ended. Enable it again to continue.")
    }
    onChange?()
  }

  private func failed(_ error: any Error) {
    lastError = error.localizedDescription
    let hadLease = leaseID != nil
    invalidate()
    if hadLease { onEnded?(error.localizedDescription) }
    onChange?()
  }

  private func lostConnection() { failed(HelperClientError.disconnected) }

  private func startMonitoring() {
    monitoring?.cancel()
    monitoring = Task { [weak self] in
      var checks = 0
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        guard let self, self.leaseID != nil else { break }
        do {
          checks += 1
          if checks % 4 == 0 { try await self.heartbeat() } else { try await self.refresh() }
        } catch { break }
      }
    }
  }
}
