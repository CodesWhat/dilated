import AppKit
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct ScriptDictionaryTests {
  @Test func dictionaryHasExactCompatibilityCodesAndARealRuntimeCommandClass() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let dictionary = try XMLDocument(
      contentsOf: root.appendingPathComponent("packaging/Dilated.sdef"))
    let commands = try dictionary.nodes(forXPath: "/dictionary/suite/command")
    #expect(commands.count == ScriptOperation.allCases.count)
    #expect(try dictionary.nodes(forXPath: "//class | //class-extension").isEmpty)
    #expect(NSClassFromString("DilatedScriptCommand") == DilatedScriptCommand.self)
    let codes = Set(
      commands.compactMap { ($0 as? XMLElement)?.attribute(forName: "code")?.stringValue })
    #expect(codes == Set(ScriptOperation.allCases.map { "amph" + $0.rawValue }))
    for node in commands {
      #expect(try node.nodes(forXPath: "cocoa/@class").first?.stringValue == "DilatedScriptCommand")
    }
    let options = try dictionary.nodes(forXPath: "//command[@code='amphcmOn']/parameter").first
    #expect((options as? XMLElement)?.attribute(forName: "name")?.stringValue == "with options")
    #expect((options as? XMLElement)?.attribute(forName: "code")?.stringValue == "optn")
    #expect(try options?.nodes(forXPath: "cocoa/@key").first?.stringValue == "options")
  }

  @Test func cocoaInstantiatesOurCommandForItsRegisteredDescription() throws {
    _ = NSApplication.shared
    let description = try #require(
      NSScriptCommandDescription(
        suiteName: "DilatedTests", commandName: "sessionIsActive",
        dictionary: [
          "AppleEventClassCode": "amph", "AppleEventCode": "cAct",
          "CommandClass": "DilatedScriptCommand", "Type": "NSNumber<Bool>",
          "ResultAppleEventCode": "bool",
        ]))
    #expect(description.appleEventClassCode == 0x616d_7068)
    #expect(description.appleEventCode == ScriptOperation.isActive.eventID)
    #expect(description.createCommandInstance() is DilatedScriptCommand)
  }
}
