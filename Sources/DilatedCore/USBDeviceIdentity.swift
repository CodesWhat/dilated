import Foundation

public struct USBDeviceIdentity: Codable, Equatable, Hashable, Sendable {
  public var vendorID: Int
  public var productID: Int
  public var serialNumber: String?

  public init(vendorID: Int, productID: Int, serialNumber: String? = nil) {
    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
  }

  public var isValid: Bool {
    (1...65535).contains(vendorID) && (0...65535).contains(productID)
      && (serialNumber.map {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.count <= 1024 && !$0.contains("\0")
      } ?? true)
  }

  public func matches(_ connected: USBDeviceIdentity) -> Bool {
    isValid && connected.isValid && vendorID == connected.vendorID
      && productID == connected.productID
      && (serialNumber == nil || serialNumber == connected.serialNumber)
  }
}
