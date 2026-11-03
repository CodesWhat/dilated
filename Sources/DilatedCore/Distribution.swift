/// Which distribution channel this binary was built for. Selected at build time by `DILATED_CHANNEL` (see Package.swift).
public enum Distribution: Sendable {
  case direct
  case mas

  public static let current: Distribution = {
    #if MAS_CHANNEL
      return .mas
    #else
      return .direct
    #endif
  }()
}
