import Foundation
import Testing

@testable import DilatedCore

struct AssertionInspectorTests {
  struct FakeSource: PowerAssertionSource {
    var byProcess: [Int32: [[String: Any]]] = [:]
    var status: [String: Int] = [:]
    func assertionsByProcess() -> [Int32: [[String: Any]]] { byProcess }
    func assertionStatus() -> [String: Int] { status }
  }

  static func assertion(_ type: String, _ name: String?) -> [String: Any] {
    var dictionary: [String: Any] = ["AssertType": type]
    if let name { dictionary["AssertName"] = name }
    return dictionary
  }

  static let names: [Int32: String] = [100: "Dilated", 200: "caffeinate"]

  @Test func ownPIDIsTaggedAsOurs() {
    let source = FakeSource(
      byProcess: [
        100: [Self.assertion("PreventUserIdleSystemSleep", "Dilated: Command line")],
        200: [Self.assertion("PreventUserIdleSystemSleep", "caffeinate command-line tool")],
      ],
      status: ["PreventUserIdleSystemSleep": 2])
    let report = AssertionInspector.report(appPID: 100, source: source) { Self.names[$0] }
    #expect(report.assertions.map(\.ours) == [true, false])
    #expect(report.assertions.map(\.processName) == ["Dilated", "caffeinate"])
    #expect(report.summary == ["PreventUserIdleSystemSleep": 2])
  }

  @Test func unknownAppPIDTagsNothing() {
    let source = FakeSource(byProcess: [100: [Self.assertion("PreventUserIdleSystemSleep", "x")]])
    let report = AssertionInspector.report(appPID: nil, source: source) { Self.names[$0] }
    #expect(report.assertions.allSatisfy { !$0.ours })
  }

  @Test func multipleAssertionsPerProcessAreAllListed() {
    let source = FakeSource(
      byProcess: [
        200: [
          Self.assertion("PreventUserIdleDisplaySleep", "display"),
          Self.assertion("PreventUserIdleSystemSleep", "system"),
          Self.assertion("NoIdleSleepAssertion", nil),
        ]
      ])
    let report = AssertionInspector.report(appPID: 100, source: source) { Self.names[$0] }
    #expect(report.assertions.count == 3)
    #expect(report.assertions.allSatisfy { $0.pid == 200 })
    #expect(
      report.assertions.map(\.type) == [
        "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep",
      ])
    #expect(report.assertions[0].name == nil)
  }

  @Test func missingProcessNameIsNilAndRendersAsUnknown() throws {
    let source = FakeSource(byProcess: [999: [Self.assertion("PreventUserIdleSystemSleep", "gone")]]
    )
    let report = AssertionInspector.report(appPID: 100, source: source) { _ in nil }
    #expect(report.assertions.first?.processName == nil)
    #expect(report.text.contains("unknown process (999)"))
    let json = try #require(String(data: report.jsonData(), encoding: .utf8))
    #expect(json.contains("\"process\" : null"))
  }

  @Test func zeroAssertionsYieldEmptyReport() throws {
    let report = AssertionInspector.report(appPID: 100, source: FakeSource()) { _ in nil }
    #expect(report.assertions.isEmpty)
    #expect(report.text == "No power assertions.")
    let object = try #require(
      JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    #expect((object["assertions"] as? [Any])?.isEmpty == true)
    #expect(object["appPID"] as? Int == 100)
  }

  @Test func jsonShapeIsStable() throws {
    let source = FakeSource(byProcess: [100: [Self.assertion("PreventUserIdleSystemSleep", "n")]])
    let report = AssertionInspector.report(appPID: nil, source: source) { _ in "p" }
    let object = try #require(
      JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    #expect(Set(object.keys) == ["appPID", "assertions", "summary"])
    #expect(object["appPID"] is NSNull)
    let entry = try #require((object["assertions"] as? [[String: Any]])?.first)
    #expect(Set(entry.keys) == ["pid", "process", "type", "name", "ours"])
  }

  @Test func systemSourceReadsRealAssertions() {
    let report = AssertionInspector.report(appPID: nil)
    #expect(report.assertions.allSatisfy { !$0.type.isEmpty && !$0.ours })
  }
}
