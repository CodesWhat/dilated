import Foundation

/// The control receives only awake state, never hold labels or settings.
public struct AwakeControlState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let appPID: Int32
  public let automationPaused: Bool
  public let hasIndefiniteHold: Bool
  public let latestExpiry: Date?

  public init(snapshot: EngineSnapshot, appPID: Int32) {
    schemaVersion = 1
    self.appPID = appPID
    automationPaused = snapshot.automationPaused
    hasIndefiniteHold = snapshot.holds.contains { $0.expiry == nil }
    latestExpiry = hasIndefiniteHold ? nil : snapshot.holds.compactMap(\.expiry).max()
  }

  public func isAwake(at now: Date, hostIsRunning: Bool) -> Bool {
    hostIsRunning && (hasIndefiniteHold || latestExpiry.map { $0 > now } == true)
  }
}

public struct AwakeControlStateStore: Sendable {
  public static let appGroup = "3524374A2S.com.codeswhat.dilated.controls"
  #if MAS_CHANNEL
    public static let hostBundleID = "com.codeswhat.dilated.appstore"
  #else
    public static let hostBundleID = "com.codeswhat.dilated"
  #endif
  public static let controlKind = hostBundleID + ".awake-control"
  private let directory: URL
  private var file: URL { directory.appendingPathComponent("awake.json") }

  public init(directory: URL) { self.directory = directory }

  public static func shared(
    containerURL: (String) -> URL? = {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }
  ) -> Self? {
    guard let container = containerURL(appGroup)
    else { return nil }
    #if MAS_CHANNEL
      let channel = "mas"
    #else
      let channel = "direct"
    #endif
    return Self(directory: container.appendingPathComponent(channel, isDirectory: true))
  }

  public func read() -> AwakeControlState? {
    guard let data = try? Data(contentsOf: file),
      let state = try? JSONDecoder().decode(AwakeControlState.self, from: data),
      state.schemaVersion == 1, state.appPID > 0
    else { return nil }
    return state
  }

  public func write(_ state: AwakeControlState) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(state).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
