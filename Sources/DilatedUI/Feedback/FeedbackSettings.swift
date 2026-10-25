import Foundation

public enum FeedbackSound: Codable, Hashable, Sendable {
  case awake, rest, extended
  case custom(id: UUID, name: String)
  var title: String {
    switch self {
    case .awake: "Awake"
    case .rest: "Rest"
    case .extended: "A little longer"
    case .custom(_, let name): name
    }
  }
  var customID: UUID? {
    if case .custom(let id, _) = self { id } else { nil }
  }
  var resource: String? {
    switch self {
    case .awake: "awake"
    case .rest: "rest"
    case .extended: "extend"
    case .custom: nil
    }
  }
}

public struct FeedbackSettings: Codable, Equatable, Sendable {
  public var notifications = false
  public var sessionStarts = true
  public var sessionEnds = true
  public var triggerStarts = true
  public var triggerEnds = true
  public var guardStops = true
  public var includeAutomation = false
  public var reminderMinutes = 0
  public var startSound = false
  public var endSound = false
  public var extendSound = false
  public var startChoice = FeedbackSound.awake
  public var endChoice = FeedbackSound.rest
  public var extendChoice = FeedbackSound.extended
  public init() {}
  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
    sessionStarts = try values.decodeIfPresent(Bool.self, forKey: .sessionStarts) ?? sessionStarts
    sessionEnds = try values.decodeIfPresent(Bool.self, forKey: .sessionEnds) ?? sessionEnds
    triggerStarts = try values.decodeIfPresent(Bool.self, forKey: .triggerStarts) ?? triggerStarts
    triggerEnds = try values.decodeIfPresent(Bool.self, forKey: .triggerEnds) ?? triggerEnds
    guardStops = try values.decodeIfPresent(Bool.self, forKey: .guardStops) ?? guardStops
    includeAutomation =
      try values.decodeIfPresent(Bool.self, forKey: .includeAutomation) ?? includeAutomation
    reminderMinutes =
      try values.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? reminderMinutes
    startSound = try values.decodeIfPresent(Bool.self, forKey: .startSound) ?? startSound
    endSound = try values.decodeIfPresent(Bool.self, forKey: .endSound) ?? endSound
    extendSound = try values.decodeIfPresent(Bool.self, forKey: .extendSound) ?? extendSound
    startChoice =
      try values.decodeIfPresent(FeedbackSound.self, forKey: .startChoice) ?? startChoice
    endChoice = try values.decodeIfPresent(FeedbackSound.self, forKey: .endChoice) ?? endChoice
    extendChoice =
      try values.decodeIfPresent(FeedbackSound.self, forKey: .extendChoice) ?? extendChoice
  }
  var validationMessage: String? {
    guard (0...1440).contains(reminderMinutes) else {
      return "Choose reminders from 1 minute to 24 hours, or Off."
    }
    for sound in [startChoice, endChoice, extendChoice] {
      if case .custom(_, let name) = sound, name.isEmpty || name.count > 200 {
        return "The custom sound name is invalid."
      }
    }
    return nil
  }
}

enum FeedbackCue: String, CaseIterable, Identifiable {
  case start = "Start"
  case end = "End"
  case extend = "Extend"
  var id: Self { self }
  var choice: WritableKeyPath<FeedbackSettings, FeedbackSound> {
    switch self {
    case .start: \.startChoice
    case .end: \.endChoice
    case .extend: \.extendChoice
    }
  }
  var enabled: WritableKeyPath<FeedbackSettings, Bool> {
    switch self {
    case .start: \.startSound
    case .end: \.endSound
    case .extend: \.extendSound
    }
  }
}
