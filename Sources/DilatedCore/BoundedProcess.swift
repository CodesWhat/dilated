import Darwin
import Foundation

struct ProcessOutcome: Sendable {
  let status: Int32
  let timedOut: Bool
  let processID: Int32
}

enum BoundedProcess {
  static func run(
    executable: URL, arguments: [String], timeout: TimeInterval
  ) async throws -> ProcessOutcome {
    guard timeout.isFinite, timeout > 0, timeout <= 3 else {
      throw ClosedLidPowerError.invalidDeadline
    }
    let operation = Task<ProcessOutcome, any Error> {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let id = process.processIdentifier
      defer { if process.isRunning { kill(id, SIGKILL) } }
      let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
      var timedOut = false
      while process.isRunning {
        if ContinuousClock.now >= deadline {
          timedOut = true
          process.terminate()
          let grace = ContinuousClock.now.advanced(by: .milliseconds(150))
          while process.isRunning && ContinuousClock.now < grace {
            try await Task.sleep(for: .milliseconds(10))
          }
          if process.isRunning { kill(id, SIGKILL) }
          let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
          while process.isRunning && ContinuousClock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(10))
          }
          guard !process.isRunning else { throw ClosedLidPowerError.childDidNotExit }
          break
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      return ProcessOutcome(status: process.terminationStatus, timedOut: timedOut, processID: id)
    }
    let result = try await operation.value
    try Task.checkCancellation()
    return result
  }
}
