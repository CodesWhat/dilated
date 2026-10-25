import Darwin
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct ActivityInputTests {
  @Test func nativeCpuAndVolumeReadingsHaveUsableValues() async throws {
    let ticks = try #require(NativeActivityInputs.cpuTicks())
    #expect(ticks.count == 4)
    var sampler = CPUUsageSampler()
    #expect(sampler.sample(ticks) == nil)
    try await Task.sleep(for: .milliseconds(150))
    let sample = sampler.sample(NativeActivityInputs.cpuTicks())
    let percentage = try #require(sample)
    #expect((0...100).contains(percentage))
    let volumes = try #require(NativeActivityInputs.mountedVolumes())
    #expect(volumes.contains("/"))
    if let idle = NativeActivityInputs.idleSeconds() { #expect(idle >= 0 && idle.isFinite) }
  }

  @Test func realDiskImageMountAndUnmountChangesOnlyItsTriggerReason() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("dilated-volume-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let image = directory.appendingPathComponent("volume.dmg")
    let mount = directory.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
    var mounted = false
    defer { if !mounted { try? FileManager.default.removeItem(at: directory) } }
    let created = try await runDiskImageTool(
      arguments: [
        "create", "-size", "8m", "-fs", "HFS+", "-volname", "Dilated trigger check", "-quiet",
        image.path,
      ], timeout: 30)
    try #require(created == 0)
    var changes = 0
    let monitor = TriggerMonitor(readPower: { .init() }, changed: { changes += 1 })
    defer { monitor.stop() }
    let rule = TriggerRule(name: "Volume check", criteria: [.volume(path: mount.path)])
    monitor.configure(rules: [rule])
    var engine = WakeEngine()
    let independent = try engine.start(source: .manual, label: "Other work")
    var evaluator = TriggerEvaluator()
    evaluator.reconcile(rules: [rule], inputs: monitor.read(), engine: &engine)
    #expect(engine.holds.count == 1)
    do {
      let attached = try await runDiskImageTool(
        arguments: [
          "attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-quiet", image.path,
        ], timeout: 30)
      mounted = NativeActivityInputs.mountedVolumes()?.contains(mount.path) == true
      try #require(attached == 0 && mounted)
      let mountDeadline = ContinuousClock.now.advanced(by: .seconds(3))
      while changes == 0, ContinuousClock.now < mountDeadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(changes > 0)
      evaluator.reconcile(rules: [rule], inputs: monitor.read(), engine: &engine)
      #expect(engine.holds.count == 2)
      changes = 0
      let detached = try await runDiskImageTool(
        arguments: ["detach", "-quiet", mount.path], timeout: 20)
      mounted = NativeActivityInputs.mountedVolumes()?.contains(mount.path) == true
      try #require(detached == 0 && !mounted)
      let unmountDeadline = ContinuousClock.now.advanced(by: .seconds(3))
      while changes == 0, ContinuousClock.now < unmountDeadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(changes > 0)
      evaluator.reconcile(rules: [rule], inputs: monitor.read(), engine: &engine)
      #expect(engine.holds.map(\.id) == [independent.id])
      #expect(monitor.pollingInterval == nil)
    } catch {
      mounted = NativeActivityInputs.mountedVolumes()?.contains(mount.path) == true
      if mounted {
        _ = try? await runDiskImageTool(arguments: ["detach", "-quiet", mount.path], timeout: 20)
        mounted = NativeActivityInputs.mountedVolumes()?.contains(mount.path) == true
      }
      throw error
    }
  }

  @Test func configuredCpuRuleGetsARealCoalescedPoll() async throws {
    var changes = 0
    let monitor = TriggerMonitor(readPower: { .init() }, changed: { changes += 1 })
    defer { monitor.stop() }
    monitor.configure(rules: [TriggerRule(name: "CPU", criteria: [.cpu(percent: 0, atLeast: true)])]
    )
    #expect(monitor.read().cpuPercent == nil)
    let start = ContinuousClock.now
    let deadline = start.advanced(by: .seconds(8))
    while ContinuousClock.now < deadline,
      changes == 0 || ContinuousClock.now < start.advanced(by: .seconds(5))
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(changes > 0)
    let percentage = try #require(monitor.read().cpuPercent)
    #expect((0...100).contains(percentage))
    monitor.stop()
    #expect(monitor.pollingInterval == nil)
  }

  @Test func activityPollingExistsOnlyForConfiguredUnpausedRules() {
    let monitor = TriggerMonitor(readPower: { .init() }, changed: {})
    defer { monitor.stop() }
    let cpu = TriggerRule(name: "CPU", criteria: [.cpu(percent: 10, atLeast: true)])
    monitor.configure(rules: [cpu])
    #expect(monitor.pollingInterval == 5)
    #expect(monitor.read().cpuPercent == nil)
    var paused = cpu
    paused.pausedUntil = Date().addingTimeInterval(60)
    monitor.configure(rules: [paused])
    #expect(monitor.pollingInterval == nil)
    #expect(monitor.read().cpuPercent == nil)
    var disabled = cpu
    disabled.enabled = false
    monitor.configure(rules: [disabled])
    #expect(monitor.pollingInterval == nil)
    monitor.configure(rules: [TriggerRule(name: "Root volume", criteria: [.volume(path: "/")])])
    #expect(monitor.pollingInterval == nil)
    #expect(monitor.read().mountedVolumes?.contains("/") == true)
    monitor.configure(rules: [
      TriggerRule(name: "Idle", criteria: [.idle(seconds: 300, atLeast: true)])
    ])
    #expect(monitor.pollingInterval == 5)
    monitor.stop()
    #expect(monitor.pollingInterval == nil)
  }
}

@MainActor private func runDiskImageTool(arguments: [String], timeout: Int) async throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  try process.run()
  defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
  let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
  while process.isRunning, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  let timedOut = process.isRunning
  if timedOut {
    kill(process.processIdentifier, SIGKILL)
    let reapDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while process.isRunning, ContinuousClock.now < reapDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  try #require(
    !process.isRunning && !timedOut, "Disk-image test command did not complete: \(arguments)")
  return process.terminationStatus
}
