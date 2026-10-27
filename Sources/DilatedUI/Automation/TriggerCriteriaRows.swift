import DilatedCore
import Foundation

/// Editor-local list of trigger conditions, each with a stable identity so SwiftUI
/// doesn't key rows (and their `@State`) by position. The saved trigger format only
/// ever sees `values`.
struct TriggerCriteriaRows: Equatable {
  struct Row: Identifiable, Equatable {
    let id = UUID()
    var value: TriggerCriterion
  }

  static let maximum = 12

  var rows: [Row]

  init(_ criteria: [TriggerCriterion]) {
    rows = criteria.map { Row(value: $0) }
  }

  var values: [TriggerCriterion] { rows.map(\.value) }
  var canAdd: Bool { rows.count < Self.maximum }

  mutating func append(_ criterion: TriggerCriterion) {
    guard canAdd else { return }
    rows.append(Row(value: criterion))
  }

  mutating func remove(id: Row.ID) {
    rows.removeAll { $0.id == id }
  }
}
