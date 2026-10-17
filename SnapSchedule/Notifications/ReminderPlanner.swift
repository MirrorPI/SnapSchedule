import Foundation

enum ReminderKind: String, CaseIterable, Equatable, Sendable {
    case dayBefore = "day-before"
    case sameDay = "same-day"
}

struct PlannedReminder: Equatable, Sendable {
    let requestID: String
    let scheduleID: UUID
    let kind: ReminderKind
    let fireDate: Date
    let title: String
    let timeZoneIdentifier: String
}

enum ReminderExclusionReason: Equatable, Sendable {
    case disabled
    case notFuture
    case invalidSchedule
}

struct ReminderExclusion: Equatable, Sendable {
    let kind: ReminderKind
    let reason: ReminderExclusionReason
}

struct ReminderPlan: Equatable, Sendable {
    let reminders: [PlannedReminder]
    let exclusions: [ReminderExclusion]
}

enum ReminderPlanner {
    static func plan(for schedule: Schedule, now: Date, includingPast: Bool = false) -> ReminderPlan {
        var reminders: [PlannedReminder] = []
        var exclusions: [ReminderExclusion] = []

        for kind in ReminderKind.allCases {
            guard isEnabled(kind, for: schedule) else {
                exclusions.append(ReminderExclusion(kind: kind, reason: .disabled))
                continue
            }
            guard
                let timeZoneIdentifier = schedule.timeZoneIdentifier,
                let timeZone = TimeZone(identifier: timeZoneIdentifier),
                schedule.date.isValidGregorianDate,
                let fireDate = fireDate(for: kind, schedule: schedule, timeZone: timeZone)
            else {
                exclusions.append(ReminderExclusion(kind: kind, reason: .invalidSchedule))
                continue
            }
            guard includingPast || fireDate > now else {
                exclusions.append(ReminderExclusion(kind: kind, reason: .notFuture))
                continue
            }

            reminders.append(PlannedReminder(
                requestID: requestID(scheduleID: schedule.id, kind: kind),
                scheduleID: schedule.id,
                kind: kind,
                fireDate: fireDate,
                title: schedule.title,
                timeZoneIdentifier: timeZoneIdentifier
            ))
        }

        return ReminderPlan(reminders: reminders, exclusions: exclusions)
    }

    static func requestID(scheduleID: UUID, kind: ReminderKind) -> String {
        "snapschedule.\(scheduleID.uuidString).\(kind.rawValue)"
    }

    private static func isEnabled(_ kind: ReminderKind, for schedule: Schedule) -> Bool {
        switch kind {
        case .dayBefore:
            schedule.notifyDayBefore
        case .sameDay:
            schedule.notifySameDay
        }
    }

    private static func fireDate(
        for kind: ReminderKind,
        schedule: Schedule,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        guard let scheduleDay = schedule.date.foundationDate(timeZone: timeZone) else {
            return nil
        }
        let dayOffset = kind == .dayBefore ? -1 : 0
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: scheduleDay) else {
            return nil
        }
        let targetDate = CalendarDate.gregorianDate(from: targetDay, timeZone: timeZone)
        let time = schedule.time ?? ClockTime(hour: 9, minute: 0)
        guard (0..<24).contains(time.hour), (0..<60).contains(time.minute) else {
            return nil
        }

        guard let startOfTargetDay = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: targetDate.year,
            month: targetDate.month,
            day: targetDate.day
        )) else {
            return nil
        }
        let searchStart = startOfTargetDay.addingTimeInterval(-1)
        guard let resolved = calendar.nextDate(
            after: searchStart,
            matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return nil
        }

        return CalendarDate.gregorianDate(from: resolved, timeZone: timeZone) == targetDate
            ? resolved
            : nil
    }
}
