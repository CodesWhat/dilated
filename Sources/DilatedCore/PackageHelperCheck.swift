import Foundation

public enum PackageHelperCheck {
  public static func verifyAbsent() async throws {
    let errors = Pipe()
    defer {
      try? errors.fileHandleForReading.close()
      try? errors.fileHandleForWriting.close()
    }
    let job = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/bin/launchctl"),
      arguments: ["print", "system/com.codeswhat.dilated.helper"], timeout: 3,
      standardError: errors.fileHandleForWriting)
    try errors.fileHandleForWriting.close()
    let detail = String(
      decoding: try errors.fileHandleForReading.read(upToCount: 8192) ?? Data(), as: UTF8.self)
    let process = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-x", "dilated-helper"],
      timeout: 3)
    try validate(
      jobStatus: job.status, jobError: detail, processStatus: process.status,
      timedOut: job.timedOut || process.timedOut)
  }

  static func validate(jobStatus: Int32, jobError: String, processStatus: Int32, timedOut: Bool)
    throws
  {
    guard !timedOut, jobStatus == 113, jobError.contains("Could not find service"),
      processStatus == 1
    else {
      throw PackageHelperError()
    }
  }
}

private struct PackageHelperError: LocalizedError {
  var errorDescription: String? {
    "Dilated's helper is still registered or running, or its state is unknown. Repeat package preparation before continuing."
  }
}
