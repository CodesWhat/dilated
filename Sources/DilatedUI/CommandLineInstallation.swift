import DilatedControl
import Foundation

struct CommandLineInstallation {
  let source: URL
  let directory: URL
  private var link: URL { directory.appendingPathComponent("dilated") }
  var isInstalled: Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == source.path
  }

  init(
    source: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dilated"),
    directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".local/bin")
  ) {
    self.source = source
    self.directory = directory
  }

  func install() throws -> String {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: source.path) else {
      throw InputError("The command line tool isn't available in this copy of Dilated.")
    }
    if isInstalled { return "The command line tool is already installed." }
    guard !hasEntry else { throw conflict }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    try files.createSymbolicLink(at: link, withDestinationURL: source)
    return "Installed the command line tool at \(link.path)."
  }

  func remove() throws -> String {
    guard isInstalled else {
      guard !hasEntry else { throw conflict }
      return "The command line tool isn't installed at \(link.path)."
    }
    try FileManager.default.removeItem(at: link)
    return "Removed the command line tool from \(link.path)."
  }

  private var hasEntry: Bool {
    FileManager.default.fileExists(atPath: link.path)
      || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
  }
  private var conflict: InputError {
    InputError("A different command already exists at \(link.path). It was left unchanged.")
  }
}
