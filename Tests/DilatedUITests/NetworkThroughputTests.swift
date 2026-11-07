import AppKit
import Darwin
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct NetworkThroughputTests {
  @Test func monitorSamplesOnlyActiveRulesAndCachesBetweenFiveSecondReads() throws {
    var reads = 0
    var uptime: TimeInterval = 0
    let monitor = TriggerMonitor(
      readPower: { .init() },
      readNetworkCounters: {
        reads += 1
        return ["en0": .init(readBytes: UInt64(uptime) * 1_000, writtenBytes: 0)]
      }, readUptime: { uptime }, changed: {})
    defer { monitor.stop() }
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 0)
    var rule = TriggerRule(
      name: "Transfer", criteria: [.networkThroughput(kilobytesPerSecond: 1, atLeast: true)])
    monitor.configure(rules: [rule])
    #expect(monitor.pollingInterval == 5)
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 1)
    uptime = 3.9
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 1)
    uptime = 5
    #expect(monitor.read().networkBytesPerSecond == 1_000 && reads == 2)
    monitor.configure(rules: [])
    #expect(monitor.pollingInterval == nil)
    uptime = 10
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 2)
    rule.enabled = false
    monitor.configure(rules: [rule])
    #expect(monitor.pollingInterval == nil)
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 2)
    rule.enabled = true
    rule.pausedUntil = Date().addingTimeInterval(3_600)
    monitor.configure(rules: [rule])
    #expect(monitor.pollingInterval == nil)
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 2)
    rule.pausedUntil = nil
    rule.enabled = true
    monitor.configure(rules: [rule])
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 3)
    monitor.stop()
    uptime = 15
    #expect(monitor.read().networkBytesPerSecond == nil && reads == 3)
  }

  @Test(arguments: [false, true])
  func timerJitterStillTakesANewSampleForNetworkAndDisk(disk: Bool) {
    var uptime: TimeInterval = 0
    var reads = 0
    func counters() -> [String: ThroughputCounters]? {
      reads += 1
      return ["fixture": .init(readBytes: UInt64(uptime * 1_000), writtenBytes: 0)]
    }
    let monitor = TriggerMonitor(
      readPower: { .init() }, readNetworkCounters: counters, readDiskCounters: counters,
      readUptime: { uptime }, workspaceNotifications: NotificationCenter(), changed: {})
    defer { monitor.stop() }
    let criterion: TriggerCriterion =
      disk
      ? .diskThroughput(kilobytesPerSecond: 1, atLeast: true)
      : .networkThroughput(kilobytesPerSecond: 1, atLeast: true)
    monitor.configure(rules: [TriggerRule(name: "Transfer", criteria: [criterion])])
    func rate() -> Double? {
      let input = monitor.read()
      return disk ? input.diskBytesPerSecond : input.networkBytesPerSecond
    }
    #expect(rate() == nil && reads == 1)
    uptime = 3.9
    #expect(rate() == nil && reads == 1)
    for (index, tick) in [4.25, 9.25, 13.5].enumerated() {
      uptime = tick
      #expect(rate() == 1_000 && reads == index + 2)
      #expect(rate() == 1_000 && reads == index + 2)
    }
    #expect(monitor.pollingInterval == 5)
  }

  @Test func failedNativeReadDoesNotMatchAnIdleNetworkCondition() {
    var reads = 0
    var uptime: TimeInterval = 0
    let monitor = TriggerMonitor(
      readPower: { .init() },
      readNetworkCounters: {
        reads += 1
        return reads == 2 ? nil : ["en0": .init(readBytes: 10, writtenBytes: 20)]
      }, readUptime: { uptime }, changed: {})
    defer { monitor.stop() }
    let rule = TriggerRule(
      name: "Below", criteria: [.networkThroughput(kilobytesPerSecond: 0, atLeast: false)])
    monitor.configure(rules: [rule])
    #expect(!rule.matches(monitor.read(), now: Date()))
    uptime = 5
    #expect(!rule.matches(monitor.read(), now: Date()))
    uptime = 10
    #expect(!rule.matches(monitor.read(), now: Date()))
    uptime = 15
    #expect(rule.matches(monitor.read(), now: Date()))
  }

  @Test func wakeDiscardsThePreSleepBaseline() {
    var uptime: TimeInterval = 0
    let notifications = NotificationCenter()
    let monitor = TriggerMonitor(
      readPower: { .init() },
      readNetworkCounters: { ["en0": .init(readBytes: UInt64(uptime) * 1_000, writtenBytes: 0)] },
      readUptime: { uptime }, workspaceNotifications: notifications, changed: {})
    defer { monitor.stop() }
    monitor.configure(rules: [
      TriggerRule(
        name: "Transfer", criteria: [.networkThroughput(kilobytesPerSecond: 1, atLeast: true)])
    ])
    #expect(monitor.read().networkBytesPerSecond == nil)
    uptime = 5
    #expect(monitor.read().networkBytesPerSecond == 1_000)
    notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
    uptime = 100
    #expect(monitor.read().networkBytesPerSecond == nil)
    uptime = 105
    #expect(monitor.read().networkBytesPerSecond == 1_000)
  }

  @Test func routingMessagesKeep64BitCountersAndIgnoreLoopbackAndDownInterfaces() throws {
    func message(index: UInt16, flags: Int32, received: UInt64, sent: UInt64) -> Data {
      var value = if_msghdr2()
      value.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
      value.ifm_version = UInt8(RTM_VERSION)
      value.ifm_type = UInt8(RTM_IFINFO2)
      value.ifm_index = index
      value.ifm_flags = flags
      value.ifm_data.ifi_ibytes = received
      value.ifm_data.ifi_obytes = sent
      return withUnsafeBytes(of: &value) { Data($0) }
    }
    let up = Int32(IFF_UP | IFF_RUNNING)
    let large = UInt64(UInt32.max) + 5_000
    let data =
      message(index: 1, flags: up | IFF_LOOPBACK, received: 100, sent: 200)
      + message(index: 2, flags: up, received: large, sent: large + 100)
      + message(index: 3, flags: 0, received: 50, sent: 60)
    let counters = try #require(
      NetworkThroughputSource.decode(data, interfaceNames: [1: "lo0", 2: "en0", 3: "en1"]))
    #expect(counters == ["2:en0": .init(readBytes: large, writtenBytes: large + 100)])
    #expect(
      NetworkThroughputSource.decode(Data(data.dropLast()), interfaceNames: [2: "en0"]) == nil)
    #expect(NetworkThroughputSource.decode(Data([0, 0, 0, 0]), interfaceNames: [:]) == nil)
  }

  @Test func realSourceReturnsKnownCountersWithoutStartingAPoller() throws {
    let counters = try #require(NetworkThroughputSource.read())
    #expect(!counters.keys.contains { $0.hasSuffix(":lo0") })
    #expect(counters.keys.allSatisfy { $0.contains(":") })
  }
}
