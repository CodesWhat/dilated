import CoreGraphics
import Darwin
import Foundation

@MainActor enum NativeActivityInputs {
  static func cpuTicks() -> [UInt32]? {
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS, count >= 4 else { return nil }
    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
  }
  static func idleSeconds() -> TimeInterval? {
    let seconds = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: .init(rawValue: ~UInt32(0))!)
    return seconds.isFinite && (0...315_576_000).contains(seconds) ? seconds : nil
  }
  static func mountedVolumes() -> Set<String>? {
    FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])
      .map { Set($0.map { $0.standardizedFileURL.path }) }
  }
}
