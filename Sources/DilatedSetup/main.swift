import Darwin
import DilatedSetupCore
import Foundation

// Hidden headless mode, for scripts/closed-lid-setup-check.sh:
//   DilatedSetup --install --yes | --remove --yes | --status --json
// It never shows the administrator prompt; a rule that needs one fails instead.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = HeadlessCommand.parse(arguments) {
  Task {
    exit(await command.run())
  }
  dispatchMain()
} else {
  SetupApp.main()
}
