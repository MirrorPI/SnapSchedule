import Foundation
import XCTest
@testable import SnapSchedule

final class ReminderPlannerTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    func testTimedScheduleUsesStoredLocalTimeForBothReminderKinds() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 9, day: 21),
            time: ClockTime(hour: 14, minute: 0),
            timeZoneIdentifier: seoul.identifier,
            notifyDayBefore: true,
            notifySameDay: true
        )

        let result = ReminderPlanner.plan(
            for: schedule,
            now: instant(2026, 9, 19, 12, 0, in: seoul)
        )

        XCTAssertEqual(result.reminders.map(\.kind), [.dayBefore, .sameDay])
        XCTAssertEqual(
            result.reminders.map(\.fireDate),
            [
                instant(2026, 9, 20, 14, 0, in: seoul),
                instant(2026, 9, 21, 14, 0, in: seoul)
            ]
        )
        XCTAssertTrue(result.exclusions.isEmpty)
    }

    func testAllDayScheduleUsesNineAMInStoredTimeZone() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 9, day: 21),
            timeZoneIdentifier: seoul.identifier,
            notifyDayBefore: true,
            notifySameDay: true
        )

        let result = ReminderPlanner.plan(
            for: schedule,
            now: instant(2026, 9, 19, 12, 0, in: seoul)
        )

        XCTAssertEqual(
            result.reminders.map(\.fireDate),
            [
                instant(2026, 9, 20, 9, 0, in: seoul),
                instant(2026, 9, 21, 9, 0, in: seoul)
            ]
        )
    }

    func testPastReminderIsExcludedWhileFutureReminderRemains() throws {
        let pastAllDay = makeSchedule(
            id: id(2),
            date: CalendarDate(year: 2026, month: 9, day: 21),
            timeZoneIdentifier: seoul.identifier,
            notifySameDay: true
        )
        let futureTimed = makeSchedule(
            id: id(3),
            date: CalendarDate(year: 2026, month: 9, day: 21),
            time: ClockTime(hour: 14, minute: 0),
            timeZoneIdentifier: seoul.identifier,
            notifySameDay: true
        )
        let now = instant(2026, 9, 21, 10, 0, in: seoul)

        let pastResult = ReminderPlanner.plan(for: pastAllDay, now: now)
        let futureResult = ReminderPlanner.plan(for: futureTimed, now: now)

        XCTAssertTrue(pastResult.reminders.isEmpty)
        XCTAssertEqual(
            pastResult.exclusions,
            [
                ReminderExclusion(kind: .dayBefore, reason: .disabled),
                ReminderExclusion(kind: .sameDay, reason: .notFuture)
            ]
        )
        XCTAssertEqual(futureResult.reminders.map(\.fireDate), [instant(2026, 9, 21, 14, 0, in: seoul)])
        XCTAssertEqual(
            futureResult.exclusions,
            [ReminderExclusion(kind: .dayBefore, reason: .disabled)]
        )
    }

    func testDisabledKindsAreOmittedAndReportedDeterministically() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 9, day: 21),
            timeZoneIdentifier: seoul.identifier
        )

        let result = ReminderPlanner.plan(
            for: schedule,
            now: instant(2026, 9, 19, 12, 0, in: seoul)
        )

        XCTAssertTrue(result.reminders.isEmpty)
        XCTAssertEqual(
            result.exclusions,
            [
                ReminderExclusion(kind: .dayBefore, reason: .disabled),
                ReminderExclusion(kind: .sameDay, reason: .disabled)
            ]
        )
    }

    func testRequestIdentifiersDependOnlyOnScheduleIDAndKind() throws {
        let schedule = makeSchedule(
            id: id(4),
            title: "Original title",
            date: CalendarDate(year: 2026, month: 9, day: 21),
            timeZoneIdentifier: seoul.identifier,
            notifyDayBefore: true,
            notifySameDay: true
        )
        let now = instant(2026, 9, 19, 12, 0, in: seoul)
        let original = ReminderPlanner.plan(for: schedule, now: now)
        schedule.title = "Renamed title"

        let renamed = ReminderPlanner.plan(for: schedule, now: now)

        XCTAssertEqual(original.reminders.map(\.requestID), renamed.reminders.map(\.requestID))
        XCTAssertEqual(
            original.reminders.map(\.requestID),
            [
                "snapschedule.20000000-0000-0000-0000-000000000004.day-before",
                "snapschedule.20000000-0000-0000-0000-000000000004.same-day"
            ]
        )
        XCTAssertEqual(renamed.reminders.map(\.title), ["Renamed title", "Renamed title"])
    }

    func testCalendarArithmeticHandlesMonthYearAndLeapDayBoundaries() throws {
        let cases: [(CalendarDate, CalendarDate)] = [
            (CalendarDate(year: 2027, month: 1, day: 1), CalendarDate(year: 2026, month: 12, day: 31)),
            (CalendarDate(year: 2026, month: 3, day: 1), CalendarDate(year: 2026, month: 2, day: 28)),
            (CalendarDate(year: 2028, month: 3, day: 1), CalendarDate(year: 2028, month: 2, day: 29))
        ]

        for (scheduleDate, expectedPreviousDate) in cases {
            let schedule = makeSchedule(
                date: scheduleDate,
                timeZoneIdentifier: seoul.identifier,
                notifyDayBefore: true
            )
            let result = ReminderPlanner.plan(
                for: schedule,
                now: instant(2025, 1, 1, 0, 0, in: seoul)
            )
            let fireDate = try XCTUnwrap(result.reminders.first?.fireDate)

            XCTAssertEqual(CalendarDate.gregorianDate(from: fireDate, timeZone: seoul), expectedPreviousDate)
            XCTAssertEqual(localHourAndMinute(fireDate, in: seoul), [9, 0])
        }
    }

    func testDSTGapMovesToNextValidTimeOnSameDay() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 3, day: 8),
            time: ClockTime(hour: 2, minute: 30),
            timeZoneIdentifier: losAngeles.identifier,
            notifySameDay: true
        )

        let result = ReminderPlanner.plan(
            for: schedule,
            now: instant(2026, 3, 7, 12, 0, in: losAngeles)
        )

        XCTAssertEqual(result.reminders.map(\.fireDate), [utcInstant(2026, 3, 8, 10, 0)])
    }

    func testDSTOverlapUsesFirstOccurrence() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 11, day: 1),
            time: ClockTime(hour: 1, minute: 30),
            timeZoneIdentifier: losAngeles.identifier,
            notifySameDay: true
        )

        let result = ReminderPlanner.plan(
            for: schedule,
            now: instant(2026, 10, 31, 12, 0, in: losAngeles)
        )

        XCTAssertEqual(result.reminders.map(\.fireDate), [utcInstant(2026, 11, 1, 8, 30)])
    }

    func testStoredTimeZoneMakesPlanIndependentOfDeviceTimeZone() throws {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 9, day: 21),
            time: ClockTime(hour: 14, minute: 0),
            timeZoneIdentifier: losAngeles.identifier,
            notifySameDay: true
        )
        let now = utcInstant(2026, 9, 20, 0, 0)

        let originalDefault = NSTimeZone.default
        defer { NSTimeZone.default = originalDefault }
        NSTimeZone.default = seoul
        let seoulDevicePlan = ReminderPlanner.plan(for: schedule, now: now)
        NSTimeZone.default = TimeZone(identifier: "Europe/London")!
        let londonDevicePlan = ReminderPlanner.plan(for: schedule, now: now)

        XCTAssertEqual(seoulDevicePlan, londonDevicePlan)
        XCTAssertEqual(
            seoulDevicePlan.reminders.map(\.fireDate),
            [instant(2026, 9, 21, 14, 0, in: losAngeles)]
        )
    }

    func testInvalidStoredTimeZoneProducesNoReminderAndExplicitReason() {
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 9, day: 21),
            timeZoneIdentifier: "Not/A_Time_Zone",
            notifyDayBefore: true,
            notifySameDay: true
        )

        let result = ReminderPlanner.plan(for: schedule, now: utcInstant(2026, 9, 1, 0, 0))

        XCTAssertTrue(result.reminders.isEmpty)
        XCTAssertEqual(
            result.exclusions,
            [
                ReminderExclusion(kind: .dayBefore, reason: .invalidSchedule),
                ReminderExclusion(kind: .sameDay, reason: .invalidSchedule)
            ]
        )
    }

    private func makeSchedule(
        id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        title: String = "Event",
        date: CalendarDate,
        time: ClockTime? = nil,
        timeZoneIdentifier: String,
        notifyDayBefore: Bool = false,
        notifySameDay: Bool = false
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: UUID(),
            title: title,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            sourceAssetIdentifier: "asset",
            notifyDayBefore: notifyDayBefore,
            notifySameDay: notifySameDay
        )
    }

    private func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func utcInstant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        instant(year, month, day, hour, minute, in: TimeZone(secondsFromGMT: 0)!)
    }

    private func localHourAndMinute(_ date: Date, in timeZone: TimeZone) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return [components.hour!, components.minute!]
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", value))!
    }
}
