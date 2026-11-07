import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

struct WeeklyScheduleGridTests {
  @Test func draggingEitherDirectionReplacesTheSameBlock() {
    let first = ScheduleGridCell(day: 2, hour: 9)
    let last = ScheduleGridCell(day: 6, hour: 16)
    let expected = WeeklySchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1020)
    #expect(ScheduleGridSelection.block(from: first, to: last) == expected)
    #expect(ScheduleGridSelection.block(from: last, to: first) == expected)
  }

  @Test func fullDayAndMidnightKeepTheExistingScheduleSemantics() {
    let wholeDay = ScheduleGridSelection.block(
      from: .init(day: 7, hour: 0), to: .init(day: 7, hour: 23))
    #expect(wholeDay == WeeklySchedule(weekdays: [7], startMinute: 0, endMinute: 0))
    let evening = ScheduleGridSelection.block(
      from: .init(day: 2, hour: 22), to: .init(day: 2, hour: 23))
    #expect(evening == WeeklySchedule(weekdays: [2], startMinute: 1320, endMinute: 0))
    #expect(ScheduleGridSelection.contains(.init(day: 2, hour: 23), in: evening))
    #expect(!ScheduleGridSelection.contains(.init(day: 3, hour: 0), in: evening))
  }

  @Test func minuteFieldsAndOvernightWindowsAreReflectedWithoutRoundingTheModel() {
    let schedule = WeeklySchedule(weekdays: [7], startMinute: 22 * 60 + 30, endMinute: 75)
    #expect(ScheduleGridSelection.contains(.init(day: 7, hour: 22), in: schedule))
    #expect(ScheduleGridSelection.contains(.init(day: 1, hour: 1), in: schedule))
    #expect(!ScheduleGridSelection.contains(.init(day: 7, hour: 21), in: schedule))
    #expect(!ScheduleGridSelection.contains(.init(day: 1, hour: 2), in: schedule))
    #expect(schedule.startMinute == 1350 && schedule.endMinute == 75)
    let cleared = ScheduleGridSelection.clearing(schedule)
    #expect(cleared.weekdays.isEmpty && !cleared.isValid)
    #expect(cleared.startMinute == schedule.startMinute && cleared.endMinute == schedule.endMinute)
  }

  @Test(arguments: [
    WeeklySchedule(weekdays: [1, 3, 7], startMinute: 0, endMinute: 0),
    WeeklySchedule(weekdays: [2, 4], startMinute: 9 * 60 + 17, endMinute: 17 * 60 + 43),
    WeeklySchedule(weekdays: [1, 7], startMinute: 22 * 60 + 30, endMinute: 75),
  ])
  func eachCellMatchesTheSchedulesActualMinutes(schedule: WeeklySchedule) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    for day in 1...7 {
      for hour in 0..<24 {
        let expected = (0..<60).contains { minute in
          let date = sunday.addingTimeInterval(
            Double((day - 1) * 86400 + hour * 3600 + minute * 60))
          return schedule.contains(date, calendar: calendar)
        }
        #expect(
          ScheduleGridSelection.contains(.init(day: day, hour: hour), in: schedule) == expected,
          "Day \(day), hour \(hour), schedule \(schedule)")
      }
    }
  }

  @Test func arrowsMoveFocusAndSpaceSelectsTheFocusedHour() {
    var cell = ScheduleGridCell(day: 1, hour: 0)
    cell = ScheduleGridSelection.moving(cell, .left)
    cell = ScheduleGridSelection.moving(cell, .up)
    #expect(cell == ScheduleGridCell(day: 1, hour: 0))
    cell = ScheduleGridSelection.moving(cell, .right)
    cell = ScheduleGridSelection.moving(cell, .down)
    #expect(cell == ScheduleGridCell(day: 2, hour: 1))
    #expect(
      ScheduleGridSelection.block(from: cell, to: cell)
        == WeeklySchedule(weekdays: [2], startMinute: 60, endMinute: 120))
    #expect(ScheduleGridSelection.moving(.init(day: 7, hour: 23), .right).day == 7)
    #expect(ScheduleGridSelection.moving(.init(day: 7, hour: 23), .down).hour == 23)
  }
}
