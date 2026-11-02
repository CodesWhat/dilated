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
  static func launcher(
    executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated")
  ) -> @Sendable (ClosedLidWatchdogLaunch) throws -> Void {
    { launch in try spawn(launch, executable: executable) }
  }

  static func spawn(_ launch: ClosedLidWatchdogLaunch, executable: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw WatchdogSpawnError(
        detail: "The crash-recovery watchdog isn't available in this copy of Dilated.")
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
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
    // The child is detached from our session but still ours to reap when it exits early.
    DispatchQueue.global().async {
      var ignored: Int32 = 0
      waitpid(child, &ignored, 0)
    }
  }
}
