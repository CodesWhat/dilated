import Darwin
import Foundation

/// Bounded replacement for `Process.waitUntilExit`, which parks the calling thread on a run loop
/// that can miss the exit and never return. Polls `isRunning` under a deadline, then kills the
/// child so a hung one fails the test instead of hanging the suite. Returns false on a timeout.
@discardableResult
func waitForExit(_ process: Process, timeout: TimeInterval = 15) -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
  while process.isRunning && ContinuousClock.now < deadline {
    Thread.sleep(forTimeInterval: 0.005)
  }
  guard process.isRunning else { return true }
  kill(process.processIdentifier, SIGKILL)
  let reap = ContinuousClock.now.advanced(by: .seconds(5))
  while process.isRunning && ContinuousClock.now < reap {
    Thread.sleep(forTimeInterval: 0.005)
  }
  return false
}
