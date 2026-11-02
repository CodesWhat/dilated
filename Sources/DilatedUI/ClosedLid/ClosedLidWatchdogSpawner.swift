import Darwin
import DilatedCore
import Foundation

struct WatchdogSpawnError: LocalizedError {
  let detail: String
  var errorDescription: String? { detail }
}

/// Starts the bundled `dilated` CLI as a watchdog in its own session, so it outlives the app
/// when the app crashes or is killed.
enum ClosedLidWatchdogSpawner {
  /// The watchdog this process started last. A newer generation replaces it: the old one is
  /// stopped here instead of lingering until its next marker poll.
  final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?

    /// Records the new child and stops the one it replaces. The signal goes out under the lock,
    /// which `reaped` also takes, so it can't reach a recycled pid.
    func replace(with child: pid_t) {
      lock.withLock {
        if let old = pid { kill(old, SIGTERM) }
        pid = child
      }
    }

    /// Called once the child is reaped, so a recycled pid is never signalled.
    func reaped(_ child: pid_t) {
      lock.withLock { if pid == child { pid = nil } }
    }

    var running: pid_t? { lock.withLock { pid } }
  }

  static let shared = Current()

  static func launcher(
    executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated"),
    current: Current = shared
  ) -> @Sendable (ClosedLidWatchdogLaunch) throws -> Void {
    { launch in try spawn(launch, executable: executable, current: current) }
  }

  @discardableResult
  static func spawn(
    _ launch: ClosedLidWatchdogLaunch, executable: URL, current: Current = shared
  ) throws -> pid_t {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw WatchdogSpawnError(
        detail: "The crash-recovery watchdog isn't available in this copy of Dilated.")
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Default signal dispositions and an empty mask, so SIGTERM stops the watchdog even if the
    // app was started with it ignored or blocked.
    var defaults = sigset_t()
    sigfillset(&defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    let arguments = [executable.path] + ClosedLidWatchdogCommand.arguments(for: launch)
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var child: pid_t = 0
    let status = posix_spawn(&child, executable.path, &actions, &attributes, &argv, [nil])
    guard status == 0 else {
      throw WatchdogSpawnError(detail: "Couldn't start the crash-recovery watchdog (\(status)).")
    }
    // At most one watchdog per app: the replaced generation's process is stopped. It only
    // reverts when the app dies, and the app is alive.
    current.replace(with: child)
    // The child is detached from our session but still ours to reap when it exits early.
    DispatchQueue.global().async {
      var ignored: Int32 = 0
      waitpid(child, &ignored, 0)
      current.reaped(child)
    }
    return child
  }
}
