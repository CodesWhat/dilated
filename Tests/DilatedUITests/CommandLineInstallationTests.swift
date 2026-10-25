import Foundation
import Testing

@testable import DilatedUI

struct CommandLineInstallationTests {
  @Test func installLinksTheBundledExecutableAndCanBeRepeated() throws {
    let fixture = try CLIInstallationFixture()
    defer { fixture.cleanUp() }
    #expect(!fixture.installation.isInstalled)
    _ = try fixture.installation.install()
    #expect(fixture.installation.isInstalled)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path)
        == fixture.source.path)
    _ = try fixture.installation.install()
    #expect(try Data(contentsOf: fixture.link) == Data("bundled CLI".utf8))
  }

  @Test func removalOnlyUnlinksTheInstalledCommand() throws {
    let fixture = try CLIInstallationFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.installation.install()
    let neighbor = fixture.directory.appendingPathComponent("another-command")
    try Data("keep".utf8).write(to: neighbor)
    _ = try fixture.installation.remove()
    #expect(!fixture.installation.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: fixture.link.path))
    #expect(try Data(contentsOf: fixture.source) == Data("bundled CLI".utf8))
    #expect(try Data(contentsOf: neighbor) == Data("keep".utf8))
    _ = try fixture.installation.remove()
  }

  @Test func unrelatedFilesDirectoriesAndLinksSurviveBothOperations() throws {
    for kind in ["file", "directory", "foreign-link", "broken-link"] {
      let fixture = try CLIInstallationFixture()
      defer { fixture.cleanUp() }
      let files = FileManager.default
      try files.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
      let other = fixture.root.appendingPathComponent("other-app")
      switch kind {
      case "file": try Data("keep".utf8).write(to: fixture.link)
      case "directory":
        try files.createDirectory(at: fixture.link, withIntermediateDirectories: false)
      default:
        if kind == "foreign-link" { try Data("keep".utf8).write(to: other) }
        try files.createSymbolicLink(at: fixture.link, withDestinationURL: other)
      }
      #expect(throws: (any Error).self) { try fixture.installation.install() }
      #expect(throws: (any Error).self) { try fixture.installation.remove() }
      if kind.hasSuffix("link") {
        #expect(try files.destinationOfSymbolicLink(atPath: fixture.link.path) == other.path)
      } else {
        #expect(files.fileExists(atPath: fixture.link.path))
        if kind == "file" { #expect(try Data(contentsOf: fixture.link) == Data("keep".utf8)) }
      }
    }
  }

  @Test func installationRequiresAnExecutableBeforeCreatingTheBinDirectory() throws {
    let fixture = try CLIInstallationFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.source.path)
    #expect(throws: (any Error).self) { try fixture.installation.install() }
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    try FileManager.default.removeItem(at: fixture.source)
    #expect(throws: (any Error).self) { try fixture.installation.install() }
  }

  @Test func anOwnedBrokenLinkCanStillBeRemoved() throws {
    let fixture = try CLIInstallationFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.installation.install()
    try FileManager.default.removeItem(at: fixture.source)
    #expect(fixture.installation.isInstalled)
    _ = try fixture.installation.remove()
    #expect(!fixture.installation.isInstalled)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path)) == nil)
  }
}

private struct CLIInstallationFixture {
  let root: URL
  let source: URL
  let directory: URL
  var link: URL { directory.appendingPathComponent("dilated") }
  var installation: CommandLineInstallation { .init(source: source, directory: directory) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    source = root.appendingPathComponent("Dilated.app/Contents/MacOS/dilated")
    directory = root.appendingPathComponent("home/.local/bin")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("bundled CLI".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
