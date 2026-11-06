import Darwin
import DilatedCore
import Foundation

enum NetworkThroughputSource {
  static func read() -> [String: ThroughputCounters]? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var names: [UInt16: String] = [:]
    var next = head
    while let pointer = next {
      let address = pointer.pointee
      next = address.ifa_next
      guard address.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let name = address.ifa_name,
        let index = UInt16(exactly: if_nametoindex(name)), index > 0,
        let interfaceName = String(validatingCString: name)
      else { continue }
      names[index] = interfaceName
    }
    // ifaddrs' if_data has 32-bit byte counters. Route interface messages carry if_data64.
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    for _ in 0..<2 {
      var length = 0
      guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0,
        length > 0, length <= 16 * 1024 * 1024
      else { return nil }
      var data = Data(count: length)
      let result = data.withUnsafeMutableBytes { buffer in
        sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0)
      }
      if result == 0 {
        guard length <= data.count else { return nil }
        return decode(data.prefix(length), interfaceNames: names)
      }
      guard errno == ENOMEM else { return nil }
    }
    return nil
  }

  static func decode(_ data: Data, interfaceNames: [UInt16: String]) -> [String:
    ThroughputCounters]?
  {
    data.withUnsafeBytes { buffer in
      var offset = 0
      var counters: [String: ThroughputCounters] = [:]
      while offset < buffer.count {
        guard buffer.count - offset >= 4 else { return nil }
        let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        guard length >= 4, length <= buffer.count - offset else { return nil }
        if buffer[offset + 3] == UInt8(RTM_IFINFO2) {
          guard length >= MemoryLayout<if_msghdr2>.size,
            buffer[offset + 2] == UInt8(RTM_VERSION)
          else { return nil }
          let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
          let required = Int32(IFF_UP | IFF_RUNNING)
          if header.ifm_flags & required == required, header.ifm_flags & IFF_LOOPBACK == 0,
            let name = interfaceNames[header.ifm_index]
          {
            counters["\(header.ifm_index):\(name)"] = ThroughputCounters(
              readBytes: header.ifm_data.ifi_ibytes, writtenBytes: header.ifm_data.ifi_obytes)
          }
        }
        offset += length
      }
      return counters
    }
  }
}
