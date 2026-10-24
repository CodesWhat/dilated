import Foundation
import Testing

@testable import DilatedCore

struct PackageHelperTests {
  @Test func onlyConfirmedAbsentServiceAndProcessAllowReplacement() throws {
    let missing = "Could not find service \"com.codeswhat.dilated.helper\" in domain for system"
    try PackageHelperCheck.validate(
      jobStatus: 113, jobError: missing, processStatus: 1, timedOut: false)
    for status: Int32 in [0, 1, 5, 112] {
      #expect(throws: (any Error).self) {
        try PackageHelperCheck.validate(
          jobStatus: status, jobError: missing, processStatus: 1, timedOut: false)
      }
    }
    for processStatus: Int32 in [0, 2, 3] {
      #expect(throws: (any Error).self) {
        try PackageHelperCheck.validate(
          jobStatus: 113, jobError: missing, processStatus: processStatus, timedOut: false)
      }
    }
    #expect(throws: (any Error).self) {
      try PackageHelperCheck.validate(
        jobStatus: 113, jobError: "unknown domain", processStatus: 1, timedOut: false)
    }
    #expect(throws: (any Error).self) {
      try PackageHelperCheck.validate(
        jobStatus: 113, jobError: missing, processStatus: 1, timedOut: true)
    }
  }
}
