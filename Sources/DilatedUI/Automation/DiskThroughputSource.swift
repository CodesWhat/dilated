import DilatedCore
import Foundation
import IOKit

enum DiskThroughputSource {
  static func read() -> [String: ThroughputCounters]? {
    guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    var counters: [String: ThroughputCounters] = [:]
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      defer { IOObjectRelease(service) }
      var identity: UInt64 = 0
      guard IORegistryEntryGetRegistryEntryID(service, &identity) == KERN_SUCCESS,
        let statistics = IORegistryEntryCreateCFProperty(
          service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          as? [String: Any],
        let value = decode(statistics)
      else { return nil }
      counters[String(identity)] = value
    }
    return counters
  }

  static func decode(_ statistics: [String: Any]) -> ThroughputCounters? {
    func count(_ key: String) -> UInt64? {
      guard let number = statistics[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return nil }
      return UInt64(number.stringValue)
    }
    guard let read = count("Bytes (Read)"), let written = count("Bytes (Write)") else { return nil }
    return ThroughputCounters(readBytes: read, writtenBytes: written)
  }
}
