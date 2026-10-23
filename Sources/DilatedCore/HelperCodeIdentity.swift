import Foundation
import Security

public enum HelperCodeIdentity {
  public static func executable(at url: URL) throws -> String {
    var code: SecStaticCode?
    try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
    guard let code else { throw IdentityError.missingSignature }
    return try digest(code)
  }

  public static func current() throws -> String {
    var running: SecCode?
    try check(SecCodeCopySelf([], &running))
    guard let running else { throw IdentityError.missingSignature }
    var code: SecStaticCode?
    try check(SecCodeCopyStaticCode(running, [], &code))
    guard let code else { throw IdentityError.missingSignature }
    return try digest(code)
  }

  private static func digest(_ code: SecStaticCode) throws -> String {
    var information: CFDictionary?
    try check(SecCodeCopySigningInformation(code, [], &information))
    guard let values = information as? [String: Any],
      let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty
    else { throw IdentityError.missingSignature }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  private static func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private enum IdentityError: LocalizedError {
    case missingSignature
    var errorDescription: String? { "The helper's signed build identity couldn't be read." }
  }
}
