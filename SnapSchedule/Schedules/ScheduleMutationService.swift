import Foundation
import SwiftData

struct ScheduleEditDraft: Equatable {
    var title: String
    var date: CalendarDate
    var includesTime: Bool
    var time: ClockTime
    var timeZoneIdentifier: String
    var notifyDayBefore: Bool
    var notifySameDay: Bool

    init(schedule: Schedule) {
        title = schedule.title
        date = schedule.date
        includesTime = schedule.time != nil
        time = schedule.time ?? ClockTime(hour: 9, minute: 0)
        timeZoneIdentifier = schedule.timeZoneIdentifier ?? TimeZone.current.identifier
        notifyDayBefore = schedule.notifyDayBefore
        notifySameDay = schedule.notifySameDay
    }

    func enablesNotification(comparedTo schedule: Schedule) -> Bool {
        (notifyDayBefore && !schedule.notifyDayBefore)
            || (notifySameDay && !schedule.notifySameDay)
    }
}

enum ScheduleMutationKind: Equatable, Sendable {
    case updated
    case deleted
}

struct ScheduleMutationResult: Equatable, Sendable {
    let scheduleID: UUID
    let kind: ScheduleMutationKind
    var widgetRefreshFailed: Bool = false
}

enum ScheduleMutationError: Error, Equatable {
    case unavailable
    case blankTitle
    case invalidDate
    case invalidTime
    case invalidTimeZone
    case saveFailed
}

@MainActor
final class ScheduleMutationService {
    typealias Save = (ModelContext) throws -> Void
    typealias WidgetSnapshotRefresh = () throws -> Void

    private let context: ModelContext
    private let now: () -> Date
    private let save: Save
    private let widgetSnapshotRefresh: WidgetSnapshotRefresh

    init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping Save = { try $0.save() },
        widgetSnapshotRefresh: WidgetSnapshotRefresh? = nil
    ) {
        self.context = context
        self.now = now
        self.save = save
        self.widgetSnapshotRefresh = widgetSnapshotRefresh ?? {
            let store = WidgetSnapshotStore()
            let schedules: [Schedule]
            do {
                schedules = try context.fetch(FetchDescriptor<Schedule>())
            } catch {
                try store.invalidate()
                throw error
            }
            _ = try store.write(schedules: schedules)
        }
    }

    func update(scheduleID: UUID, draft: ScheduleEditDraft) throws -> ScheduleMutationResult {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw ScheduleMutationError.blankTitle }
        guard draft.date.isValidGregorianDate else { throw ScheduleMutationError.invalidDate }
        if draft.includesTime,
           !((0..<24).contains(draft.time.hour) && (0..<60).contains(draft.time.minute)) {
            throw ScheduleMutationError.invalidTime
        }
        guard TimeZone(identifier: draft.timeZoneIdentifier) != nil else {
            throw ScheduleMutationError.invalidTimeZone
        }

        let schedule = try storedSchedule(id: scheduleID)
        let original = StoredScheduleValues(schedule: schedule)
        schedule.title = normalizedTitle
        schedule.date = draft.date
        schedule.time = draft.includesTime ? draft.time : nil
        schedule.timeZoneIdentifier = draft.timeZoneIdentifier
        schedule.notifyDayBefore = draft.notifyDayBefore
        schedule.notifySameDay = draft.notifySameDay
        schedule.updatedAt = now()

        do {
            try save(context)
        } catch {
            original.restore(to: schedule)
            context.rollback()
            throw ScheduleMutationError.saveFailed
        }
        return resultAfterWidgetRefresh(scheduleID: scheduleID, kind: .updated)
    }

    func delete(scheduleID: UUID) throws -> ScheduleMutationResult {
        let schedule = try storedSchedule(id: scheduleID)
        context.delete(schedule)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw ScheduleMutationError.saveFailed
        }
        return resultAfterWidgetRefresh(scheduleID: scheduleID, kind: .deleted)
    }

    func retryWidgetSnapshotRefresh() throws {
        try widgetSnapshotRefresh()
    }

    private func resultAfterWidgetRefresh(scheduleID: UUID, kind: ScheduleMutationKind) -> ScheduleMutationResult {
        do {
            try widgetSnapshotRefresh()
            return ScheduleMutationResult(scheduleID: scheduleID, kind: kind)
        } catch {
            return ScheduleMutationResult(scheduleID: scheduleID, kind: kind, widgetRefreshFailed: true)
        }
    }

    private func storedSchedule(id: UUID) throws -> Schedule {
        do {
            guard let schedule = try context.fetch(FetchDescriptor<Schedule>()).first(where: { $0.id == id }) else {
                throw ScheduleMutationError.unavailable
            }
            return schedule
        } catch let error as ScheduleMutationError {
            throw error
        } catch {
            throw ScheduleMutationError.saveFailed
        }
    }
}

private struct StoredScheduleValues {
    let title: String
    let date: CalendarDate
    let time: ClockTime?
    let timeZoneIdentifier: String?
    let notifyDayBefore: Bool
    let notifySameDay: Bool
    let updatedAt: Date

    init(schedule: Schedule) {
        title = schedule.title
        date = schedule.date
        time = schedule.time
        timeZoneIdentifier = schedule.timeZoneIdentifier
        notifyDayBefore = schedule.notifyDayBefore
        notifySameDay = schedule.notifySameDay
        updatedAt = schedule.updatedAt
    }

    func restore(to schedule: Schedule) {
        schedule.title = title
        schedule.date = date
        schedule.time = time
        schedule.timeZoneIdentifier = timeZoneIdentifier
        schedule.notifyDayBefore = notifyDayBefore
        schedule.notifySameDay = notifySameDay
        schedule.updatedAt = updatedAt
    }
}
