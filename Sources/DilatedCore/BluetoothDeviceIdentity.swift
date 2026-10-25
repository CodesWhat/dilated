import Foundation

public struct BluetoothDeviceIdentity: Codable, Equatable, Hashable, Sendable {
  public let address: String

  public init?(address: String) {
    let separator: Character = address.contains(":") ? ":" : "-"
    let parts = address.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count == 6,
      parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy(Self.isHex) })
    else { return nil }
    let bytes = parts.compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 6,
      bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 255 })
    else { return nil }
    self.address = parts.map { $0.lowercased() }.joined(separator: ":")
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let identity = Self(address: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid Bluetooth address.")
    }
    self = identity
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(address)
  }
}
