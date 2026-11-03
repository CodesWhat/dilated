import DilatedSetupCore
import Foundation

enum HeadlessCommand: Equatable {
  case install, remove, status

  /// Nil when the arguments aren't one of the hidden modes, so the window opens instead.
  /// `--install` and `--remove` need `--yes`; `--status` needs `--json`.
  static func parse(_ arguments: [String]) -> HeadlessCommand? {
    let flags = Set(arguments)
    guard flags.count == arguments.count else { return nil }
    if flags == ["--install", "--yes"] { return .install }
    if flags == ["--remove", "--yes"] { return .remove }
    if flags == ["--status", "--json"] { return .status }
    return nil
  }

  func run() async -> Int32 {
    let setup = ClosedLidSetup.live(allowAdminPrompt: false)
    switch self {
    case .status:
      print(await setup.status().jsonString)
      return 0
    case .install:
      return report(await setup.install())
    case .remove:
      return report(await setup.remove())
    }
  }

  private func report(_ outcome: ClosedLidSetupOutcome) -> Int32 {
    switch outcome {
    case .completed:
      print("ok")
      return 0
    case .cancelled:
      FileHandle.standardError.write(Data("cancelled\n".utf8))
      return 2
    case .failed(let message):
      FileHandle.standardError.write(Data("failed: \(message)\n".utf8))
      return 1
    }
  }
}
