import DilatedCore
import Foundation

@MainActor public protocol HelperTransporting: AnyObject {
  var onDisconnect: (() -> Void)? { get set }
  func send(_ request: HelperRequest) async throws -> HelperReply
  func invalidate()
}

public enum HelperClientError: LocalizedError {
  case disconnected, timedOut, invalidReply, helperUpdate
  case rejected(String)
  public var errorDescription: String? {
    switch self {
    case .disconnected: "Closed-lid stopped. Enable closed-lid again to continue."
    case .timedOut: "Closed-lid didn't respond in time. Its safety lease will expire."
    case .invalidReply: "Closed-lid returned an invalid reply."
    case .helperUpdate: "Closed-lid needs an update. Restart Dilated."
    case .rejected(let message): message
    }
  }
}
