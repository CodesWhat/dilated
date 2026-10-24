import AppKit
import Carbon
import DilatedControl

public struct ScriptStartOptions: Sendable {
  public var duration: TimeInterval?
  public var usesDefaultDuration: Bool
  public var displaySleepAllowed: Bool?

  public init(
    duration: TimeInterval? = nil, usesDefaultDuration: Bool = false,
    displaySleepAllowed: Bool? = nil
  ) {
    self.duration = duration
    self.usesDefaultDuration = usesDefaultDuration
    self.displaySleepAllowed = displaySleepAllowed
  }

  static func parse(_ record: NSAppleEventDescriptor?) throws -> Self {
    guard let record else { return .init(usesDefaultDuration: true) }
    guard record.descriptorType == typeAERecord,
      record.numberOfItems == 0
        || (record.numberOfItems == 1
          && record.keywordForDescriptor(at: 1) == keyASUserRecordFields)
    else {
      throw InputError("Options must be a record of duration, interval and displaySleepAllowed.")
    }
    var fields: [String: NSAppleEventDescriptor] = [:]
    if let list = record.forKeyword(AEKeyword(keyASUserRecordFields)) {
      guard list.descriptorType == typeAEList, list.numberOfItems % 2 == 0,
        list.numberOfItems <= 6
      else { throw InputError("Invalid options record.") }
      for index in stride(from: 1, to: list.numberOfItems + 1, by: 2) {
        guard let name = list.atIndex(index)?.stringValue?.lowercased(),
          ["duration", "interval", "displaysleepallowed"].contains(name), fields[name] == nil,
          let value = list.atIndex(index + 1)
        else {
          throw InputError(
            "Unknown or repeated option. Use duration, interval and displaySleepAllowed.")
        }
        fields[name] = value
      }
    }
    var result = Self(usesDefaultDuration: true)
    if let display = fields["displaysleepallowed"] {
      guard [typeBoolean, typeTrue, typeFalse].contains(display.descriptorType) else {
        throw InputError("displaySleepAllowed must be true or false.")
      }
      result.displaySleepAllowed = display.booleanValue
    }
    if fields["duration"] != nil || fields["interval"] != nil {
      guard let duration = fields["duration"], let interval = fields["interval"],
        [typeSInt16, typeSInt32, typeSInt64, typeUInt32].contains(duration.descriptorType)
      else { throw InputError("Provide an integer duration and its interval together.") }
      guard let numeric = duration.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint))
      else {
        throw InputError("Invalid duration value.")
      }
      let amount = numeric.doubleValue
      let unit: Double
      switch interval.descriptorType {
      case typeSInt16, typeSInt32, typeSInt64, typeUInt32,
        typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
        unit = interval.doubleValue
      default: throw InputError("interval must be a number, such as minutes or hours.")
      }
      guard amount.isFinite, amount >= 0, unit.isFinite, unit >= 0 else {
        throw InputError("Duration and interval must be finite and nonnegative.")
      }
      result.usesDefaultDuration = false
      if amount == 0 && unit == 0 { return result }
      let seconds = amount * unit
      guard amount > 0, unit > 0, seconds.isFinite, seconds > 0, seconds <= 315_576_000 else {
        throw InputError(
          "Duration must be positive and no more than ten years, or use duration:0, interval:0.")
      }
      result.duration = seconds
    }
    return result
  }
}
