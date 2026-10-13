import Foundation

enum ScheduleDayDisplay: Equatable, Sendable {
    case today
    case future(days: Int)
    case past(CalendarDate)

    var dDayText: String? {
        switch self {
        case .today:
            "D-DAY"
        case let .future(days):
            "D-\(days)"
        case .past:
            nil
        }
    }
}

struct ScheduleDatePresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let date: CalendarDate
    let time: ClockTime?
    let eventDate: Date?
    let effectiveTimeZoneIdentifier: String
    let displayTimeZoneIdentifier: String?
    let dayDisplay: ScheduleDayDisplay
    let isUpcoming: Bool

    static func sorted(
        _ schedules: [Schedule],
        now: Date,
        deviceTimeZone: TimeZone
    ) -> [ScheduleDatePresentation] {
        schedules
            .map { presentation(for: $0, now: now, deviceTimeZone: deviceTimeZone) }
            .sorted(by: comesBefore)
    }

    static func upcoming(
        _ schedules: [Schedule],
        now: Date,
        deviceTimeZone: TimeZone
    ) -> [ScheduleDatePresentation] {
        sorted(schedules, now: now, deviceTimeZone: deviceTimeZone)
            .filter(\.isUpcoming)
    }

    private static func presentation(
        for schedule: Schedule,
        now: Date,
        deviceTimeZone: TimeZone
    ) -> ScheduleDatePresentation {
        let eventTimeZone = schedule.time.flatMap { _ in
            schedule.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        } ?? deviceTimeZone
        let comparisonTimeZone = schedule.time == nil ? deviceTimeZone : eventTimeZone
        let today = CalendarDate.gregorianDate(from: now, timeZone: comparisonTimeZone)
        let difference = dayDifference(
            from: today,
            to: schedule.date,
            timeZone: comparisonTimeZone
        )
        let dayDisplay: ScheduleDayDisplay
        if difference < 0 {
            dayDisplay = .past(schedule.date)
        } else if difference == 0 {
            dayDisplay = .today
        } else {
            dayDisplay = .future(days: difference)
        }

        let eventDate = schedule.time.flatMap {
            foundationDate(date: schedule.date, time: $0, timeZone: eventTimeZone)
        }
        let isUpcoming = eventDate.map { $0 >= now } ?? (difference >= 0)
        let displayedTimeZone = schedule.time != nil && eventTimeZone.identifier != deviceTimeZone.identifier
            ? eventTimeZone.identifier
            : nil

        return ScheduleDatePresentation(
            id: schedule.id,
            title: schedule.title,
            date: schedule.date,
            time: schedule.time,
            eventDate: eventDate,
            effectiveTimeZoneIdentifier: eventTimeZone.identifier,
            displayTimeZoneIdentifier: displayedTimeZone,
            dayDisplay: dayDisplay,
            isUpcoming: isUpcoming
        )
    }

    private static func comesBefore(
        _ lhs: ScheduleDatePresentation,
        _ rhs: ScheduleDatePresentation
    ) -> Bool {
        let lhsDate = (lhs.date.year, lhs.date.month, lhs.date.day)
        let rhsDate = (rhs.date.year, rhs.date.month, rhs.date.day)
        if lhsDate != rhsDate {
            if lhs.date.year != rhs.date.year { return lhs.date.year < rhs.date.year }
            if lhs.date.month != rhs.date.month { return lhs.date.month < rhs.date.month }
            return lhs.date.day < rhs.date.day
        }
        switch (lhs.time, rhs.time) {
        case (nil, nil):
            break
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (lhsTime?, rhsTime?):
            if lhsTime.hour != rhsTime.hour { return lhsTime.hour < rhsTime.hour }
            if lhsTime.minute != rhsTime.minute { return lhsTime.minute < rhsTime.minute }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func dayDifference(
        from start: CalendarDate,
        to end: CalendarDate,
        timeZone: TimeZone
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDate = calendar.date(from: DateComponents(
            year: start.year,
            month: start.month,
            day: start.day,
            hour: 12
        ))!
        let endDate = calendar.date(from: DateComponents(
            year: end.year,
            month: end.month,
            day: end.day,
            hour: 12
        ))!
        return calendar.dateComponents([.day], from: startDate, to: endDate).day!
    }

    private static func foundationDate(
        date: CalendarDate,
        time: ClockTime,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: time.hour,
            minute: time.minute
        ))
    }
}
