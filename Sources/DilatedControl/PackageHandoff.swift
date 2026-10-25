import Foundation

public enum PackageIntent: String, Codable, Sendable { case update, uninstall }
public struct PackageHandoff: Codable, Sendable {
  public var intent: PackageIntent
  public var appPath: String
  public var preparedAt: Date
  public var helperWasApproved: Bool
  public init(
    intent: PackageIntent, appPath: String, preparedAt: Date, helperWasApproved: Bool = false
  ) {
    self.intent = intent
    self.appPath = appPath
    self.preparedAt = preparedAt
    self.helperWasApproved = helperWasApproved
  }
}
public struct PackageHandoffStore {
  public let directory: URL
  private var file: URL { directory.appendingPathComponent("package-handoff.json") }
  public init(directory: URL) { self.directory = directory }
  public func save(_ handoff: PackageHandoff) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(handoff).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  public func clear() throws {
    do { try FileManager.default.removeItem(at: file) } catch let error as CocoaError
      where error.code == .fileNoSuchFile
    {}
  }
  public func requirePrepared(app: URL, now: Date = Date()) throws -> PackageHandoff {
    guard let data = try? Data(contentsOf: file), data.count <= 16384,
      let handoff = try? JSONDecoder().decode(PackageHandoff.self, from: data),
      handoff.appPath == app.resolvingSymlinksInPath().path,
      (0...600).contains(now.timeIntervalSince(handoff.preparedAt))
    else {
      throw InputError(
        "Run dilated prepare-update before upgrading, or dilated prepare-uninstall before removal. Preparation is valid for ten minutes."
      )
    }
    return handoff
  }
}
