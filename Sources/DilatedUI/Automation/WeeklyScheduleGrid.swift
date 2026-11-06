import DilatedCore
import SwiftUI

struct ScheduleGridCell: Hashable {
  let day: Int
  let hour: Int
}

enum ScheduleGridSelection {
  enum Direction { case left, right, up, down }

  static func block(from first: ScheduleGridCell, to last: ScheduleGridCell) -> WeeklySchedule {
    WeeklySchedule(
      weekdays: Set(min(first.day, last.day)...max(first.day, last.day)),
      startMinute: min(first.hour, last.hour) * 60,
      endMinute: ((max(first.hour, last.hour) + 1) % 24) * 60)
  }

  static func clearing(_ schedule: WeeklySchedule) -> WeeklySchedule {
    var result = schedule
    result.weekdays = []
    return result
  }

  static func contains(_ cell: ScheduleGridCell, in schedule: WeeklySchedule) -> Bool {
    let start = cell.hour * 60
    let end = start + 60
    if schedule.startMinute == schedule.endMinute { return schedule.weekdays.contains(cell.day) }
    if schedule.startMinute < schedule.endMinute {
      return schedule.weekdays.contains(cell.day)
        && start < schedule.endMinute && end > schedule.startMinute
    }
    let previous = cell.day == 1 ? 7 : cell.day - 1
    return (schedule.weekdays.contains(cell.day) && end > schedule.startMinute)
      || (schedule.weekdays.contains(previous) && start < schedule.endMinute)
  }

  static func moving(_ cell: ScheduleGridCell, _ direction: Direction) -> ScheduleGridCell {
    switch direction {
    case .left: ScheduleGridCell(day: max(1, cell.day - 1), hour: cell.hour)
    case .right: ScheduleGridCell(day: min(7, cell.day + 1), hour: cell.hour)
    case .up: ScheduleGridCell(day: cell.day, hour: max(0, cell.hour - 1))
    case .down: ScheduleGridCell(day: cell.day, hour: min(23, cell.hour + 1))
    }
  }
}

struct WeeklyScheduleGrid: View {
  #if DEBUG
    var didAppear: ((Self) -> Void)?
  #endif
  @Binding var schedule: WeeklySchedule
  @State private var cell = ScheduleGridCell(day: 2, hour: 9)
  @FocusState private var focused: Bool
  private let rowHeight: CGFloat = 14

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 0) {
        Color.clear.frame(width: 32, height: 1)
        ForEach(1...7, id: \.self) { day in
          Text(Calendar.current.shortWeekdaySymbols[day - 1]).frame(maxWidth: .infinity)
        }
      }.font(.caption)
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          ForEach(0..<24, id: \.self) { hour in
            Text(hour.isMultiple(of: 3) ? String(format: "%02d", hour) : "")
              .font(.caption2).frame(width: 32, height: rowHeight, alignment: .leading)
          }
        }.accessibilityHidden(true)
        GeometryReader { geometry in
          Canvas { context, size in
            let width = size.width / 7
            for hour in 0..<24 {
              for day in 1...7 {
                let value = ScheduleGridCell(day: day, hour: hour)
                let rect = CGRect(
                  x: CGFloat(day - 1) * width + 1, y: CGFloat(hour) * rowHeight + 1,
                  width: max(0, width - 2), height: rowHeight - 2)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(
                  path,
                  with: .color(
                    ScheduleGridSelection.contains(value, in: schedule)
                      ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.12)))
                if focused && value == cell {
                  context.stroke(path, with: .color(.primary), lineWidth: 2)
                }
              }
            }
          }
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { drag in
                selectBlock(from: drag.startLocation, to: drag.location, width: geometry.size.width)
              })
        }
        .focusable().focused($focused)
        .onMoveCommand { direction in
          switch direction {
          case .left: move(.left)
          case .right: move(.right)
          case .up: move(.up)
          case .down: move(.down)
          @unknown default: break
          }
        }
        .onKeyPress(.space) {
          selectFocusedHour()
          return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekly schedule grid")
        .accessibilityValue(focusDescription)
        .accessibilityHint(
          "Use arrow keys to move and Space to select an hour. Precise times are below."
        )
        .accessibilityAction(named: "Select focused hour", selectFocusedHour)
        .accessibilityAction(named: "Previous day") { move(.left) }
        .accessibilityAction(named: "Next day") { move(.right) }
        .accessibilityAction(named: "Previous hour") { move(.up) }
        .accessibilityAction(named: "Next hour") { move(.down) }
      }.frame(height: rowHeight * 24)
      HStack {
        Text(focusDescription).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Clear schedule") { schedule = ScheduleGridSelection.clearing(schedule) }
      }
      Text(
        "Drag a block to replace the days and hours. Use the fields below for precise or overnight times."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    #if DEBUG
      .onAppear { didAppear?(self) }
    #endif
  }

  private var focusDescription: String {
    let selected = ScheduleGridSelection.contains(cell, in: schedule) ? "selected" : "not selected"
    return
      "\(Calendar.current.weekdaySymbols[cell.day - 1]), \(String(format: "%02d:00", cell.hour)), \(selected)"
  }

  private func hit(_ point: CGPoint, width: CGFloat) -> ScheduleGridCell {
    ScheduleGridCell(
      day: max(1, min(7, Int(point.x / max(1, width / 7)) + 1)),
      hour: max(0, min(23, Int(point.y / rowHeight))))
  }

  private func move(_ direction: ScheduleGridSelection.Direction) {
    cell = ScheduleGridSelection.moving(cell, direction)
  }

  func selectBlock(from first: CGPoint, to last: CGPoint, width: CGFloat) {
    focused = true
    cell = hit(last, width: width)
    schedule = ScheduleGridSelection.block(from: hit(first, width: width), to: cell)
  }

  func selectFocusedHour() {
    schedule = ScheduleGridSelection.block(from: cell, to: cell)
  }
}
