import AppKit
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct DiskThroughputTests {
  @Test func diskAndNetworkSharePollingAndRemovingDiskStopsOnlyItsReads() {
    var uptime: TimeInterval = 0
    var networkReads = 0
    var diskReads = 0
    let notifications = NotificationCenter()
    let monitor = TriggerMonitor(
      readPower: { .init() },
      readNetworkCounters: {
        networkReads += 1
        return ["en0": .init(readBytes: UInt64(uptime) * 1_000, writtenBytes: 0)]
      },
      readDiskCounters: {
        diskReads += 1
        return ["disk": .init(readBytes: 0, writtenBytes: UInt64(uptime) * 2_000)]
      }, readUptime: { uptime }, workspaceNotifications: notifications, changed: {})
    defer { monitor.stop() }
    _ = monitor.read()
    #expect(networkReads == 0 && diskReads == 0)
    let network = TriggerRule(
      name: "Network", criteria: [.networkThroughput(kilobytesPerSecond: 1, atLeast: true)])
    let disk = TriggerRule(
      name: "Disk", criteria: [.diskThroughput(kilobytesPerSecond: 1, atLeast: true)])
    monitor.configure(rules: [network, disk])
    #expect(monitor.pollingInterval == 5)
    #expect(monitor.read().diskBytesPerSecond == nil)
    uptime = 5
    let values = monitor.read()
    #expect(values.diskBytesPerSecond == 2_000 && values.networkBytesPerSecond == 1_000)
    _ = monitor.read()
    #expect(networkReads == 2 && diskReads == 2)
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    uptime = 100
    #expect(monitor.read().diskBytesPerSecond == nil)
    monitor.configure(rules: [network])
    uptime = 105
    #expect(monitor.read().diskBytesPerSecond == nil)
    #expect(diskReads == 3 && networkReads == 4 && monitor.pollingInterval == 5)
    monitor.configure(rules: [])
    uptime = 110
    _ = monitor.read()
    #expect(diskReads == 3 && networkReads == 4 && monitor.pollingInterval == nil)
    var paused = disk
    paused.pausedUntil = Date().addingTimeInterval(3_600)
    monitor.configure(rules: [paused])
    _ = monitor.read()
    #expect(diskReads == 3 && monitor.pollingInterval == nil)
    monitor.configure(rules: [disk])
    #expect(monitor.read().diskBytesPerSecond == nil)
    #expect(diskReads == 4)
    monitor.stop()
    _ = monitor.read()
    #expect(diskReads == 4 && monitor.pollingInterval == nil)
  }

  @Test func unavailableDiskCountersCannotMatchAnIdleRule() {
    let monitor = TriggerMonitor(readPower: { .init() }, readDiskCounters: { nil }, changed: {})
    defer { monitor.stop() }
    let rule = TriggerRule(
      name: "Idle", criteria: [.diskThroughput(kilobytesPerSecond: 0, atLeast: false)])
    monitor.configure(rules: [rule])
    #expect(!rule.matches(monitor.read(), now: Date()))
  }

  @Test func statisticsRequireExactNonnegativeIntegerCounters() throws {
    let large = UInt64(UInt32.max) + 5_000
    #expect(
      DiskThroughputSource.decode([
        "Bytes (Read)": NSNumber(value: large), "Bytes (Write)": NSNumber(value: UInt64.max),
      ]) == .init(readBytes: large, writtenBytes: .max))
    let malformed: [Any] = [
      NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true),
      NSNumber(value: Double.infinity), "100",
    ]
    for bad in malformed {
      #expect(
        DiskThroughputSource.decode(["Bytes (Read)": bad, "Bytes (Write)": NSNumber(value: 0)])
          == nil)
    }
    #expect(DiskThroughputSource.decode([:]) == nil)
    let counters = try #require(DiskThroughputSource.read())
    #expect(counters.keys.allSatisfy { UInt64($0) != nil })
  }
}
