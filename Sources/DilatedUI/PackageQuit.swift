import AppKit

/// Once the app has told the CLI it is prepared (and so reports "quitting"), it has to actually
/// exit. Asks AppKit to terminate, then exits the process outright if that hasn't finished within
/// `grace`. The deadline runs on a background queue so a blocked main thread can't stall it.
/// State is already saved by the time this runs.
@MainActor struct PackageQuit {
  var delay: Duration = .seconds(1)
  var grace: TimeInterval = 5
  var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
  var forceExit: @Sendable () -> Void = { _exit(0) }

  func run() async {
    try? await Task.sleep(for: delay)
    // Armed first: with `.terminateLater` AppKit may run a modal loop inside terminate() and
    // not return, so the fallback can't wait until after it.
    let forceExit = forceExit
    DispatchQueue.global().asyncAfter(deadline: .now() + grace) { forceExit() }
    terminate()
  }
}
