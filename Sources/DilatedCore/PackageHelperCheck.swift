import Foundation

public enum PackageHelperCheck {
  public static func verifyAbsent(appExecutable: URL) async throws {
    try await verifyAppAbsent(executable: appExecutable)
    try await verifyHelperAbsent()
  }

  public static func verifyHelperAbsent() async throws {
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

  public enum JobState: Equatable, Sendable { case loaded, absent, unknown }

  /// Whether launchd still has the retired helper's system job. Only a clean "could not find
  /// service" answer counts as absent.
  public static func helperJobState() async -> JobState {
    let errors = Pipe()
    defer {
      try? errors.fileHandleForReading.close()
      try? errors.fileHandleForWriting.close()
    }
    guard
      let job = try? await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/bin/launchctl"),
        arguments: ["print", "system/com.codeswhat.dilated.helper"], timeout: 3,
        standardError: errors.fileHandleForWriting)
    else { return .unknown }
    try? errors.fileHandleForWriting.close()
    let detail = String(
      decoding: (try? errors.fileHandleForReading.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
    if job.timedOut { return .unknown }
    if job.status == 0 { return .loaded }
    return job.status == 113 && detail.contains("Could not find service") ? .absent : .unknown
  }

  static func verifyAppAbsent(executable: URL) async throws {
    let special = Set(".[]{}()^$*+?|\\")
    let literal = executable.path.map { special.contains($0) ? "\\" + String($0) : String($0) }
      .joined()
    let result = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
      arguments: ["-i", "-f", "^" + literal + "($|[[:space:]])"], timeout: 3)
    guard !result.timedOut, result.status == 1 else {
      throw NSError(
        domain: "Dilated.Package", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Dilated is still running, or its process state is unknown. Quit it before replacing the app."
        ])
    }
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
