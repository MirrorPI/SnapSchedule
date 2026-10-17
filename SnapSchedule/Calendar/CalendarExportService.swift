import EventKit
import Foundation
import SwiftData

enum CalendarAuthorizationAccess: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case unknown

    var allowsWriting: Bool {
        self == .writeOnly || self == .fullAccess
    }

    var displayName: String {
        switch self {
        case .notDetermined: String(localized: "Not requested")
        case .restricted: String(localized: "Restricted")
        case .denied: String(localized: "Denied")
        case .writeOnly: String(localized: "Add only")
        case .fullAccess: String(localized: "Full access")
        case .unknown: String(localized: "Unavailable")
        }
    }

    static var current: CalendarAuthorizationAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        @unknown default: .unknown
        }
    }
}

struct CalendarEventDraft: Equatable, Sendable {
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let timeZoneIdentifier: String
    let alarms: [TimeInterval]
}

@MainActor
protocol CalendarEventWriting: AnyObject {
    var access: CalendarAuthorizationAccess { get }
    func requestWriteOnlyAccess() async throws -> CalendarAuthorizationAccess
    func save(_ event: CalendarEventDraft) throws -> String?
}

enum CalendarEventWriterError: Error {
    case noDefaultCalendar
}

@MainActor
final class SystemCalendarEventWriter: CalendarEventWriting {
    static let shared = SystemCalendarEventWriter()

    private let eventStore = EKEventStore()

    var access: CalendarAuthorizationAccess {
        .current
    }

    func requestWriteOnlyAccess() async throws -> CalendarAuthorizationAccess {
        _ = try await eventStore.requestWriteOnlyAccessToEvents()
        return .current
    }

    func save(_ draft: CalendarEventDraft) throws -> String? {
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarEventWriterError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = draft.isAllDay
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
        try eventStore.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }
}

enum CalendarExportFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidSchedule
    case accessDenied
    case accessRestricted
    case accessRequestFailed
    case eventSaveFailed
    case localStateSaveFailed

    var message: String {
        switch self {
        case .unavailable:
            String(localized: "The schedule is no longer available.")
        case .invalidSchedule:
            String(localized: "The schedule date, time, or time zone is invalid.")
        case .accessDenied:
            String(localized: "Calendar access is denied. The schedule remains saved in SnapSchedule.")
        case .accessRestricted:
            String(localized: "Calendar access is restricted on this device. The schedule remains saved in SnapSchedule.")
        case .accessRequestFailed:
            String(localized: "Calendar permission could not be requested. Please try again.")
        case .eventSaveFailed:
            String(localized: "The Calendar copy could not be added. Please try again.")
        case .localStateSaveFailed:
            String(localized: "Calendar was not changed, but the export state could not be saved. Please try again.")
        }
    }

    // Stable English catalog keys in storage; display uses the current app language.
    var storageMessage: String {
        switch self {
        case .unavailable:
            "The schedule is no longer available."
        case .invalidSchedule:
            "The schedule date, time, or time zone is invalid."
        case .accessDenied:
            "Calendar access is denied. The schedule remains saved in SnapSchedule."
        case .accessRestricted:
            "Calendar access is restricted on this device. The schedule remains saved in SnapSchedule."
        case .accessRequestFailed:
            "Calendar permission could not be requested. Please try again."
        case .eventSaveFailed:
            "The Calendar copy could not be added. Please try again."
        case .localStateSaveFailed:
            "Calendar was not changed, but the export state could not be saved. Please try again."
        }
    }
}

enum CalendarExportResult: Equatable, Sendable {
    case succeeded
    case alreadySucceeded
    case confirmationRequired
    case failed(CalendarExportFailure)
    case unknown
}

struct CalendarExportSummary: Equatable, Sendable {
    let succeededCount: Int
    let failedCount: Int
    let unknownCount: Int
}

@MainActor
final class CalendarExportService {
    typealias Save = (ModelContext) throws -> Void

    private let context: ModelContext
    private let writer: any CalendarEventWriting
    private let save: Save

    init(
        context: ModelContext,
        writer: any CalendarEventWriting = SystemCalendarEventWriter.shared,
        save: @escaping Save = { try $0.save() }
    ) {
        self.context = context
        self.writer = writer
        self.save = save
    }

    func recoverInterruptedExports() throws -> Int {
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        let interrupted = schedules.filter { $0.calendarExportStatus == .exporting }
        guard !interrupted.isEmpty else { return 0 }

        for schedule in interrupted {
            markUnknown(schedule)
        }
        do {
            try save(context)
            return interrupted.count
        } catch {
            context.rollback()
            throw error
        }
    }

    func exportRequested(scheduleIDs: [UUID]) async throws -> CalendarExportSummary {
        let requestedIDs = Set(scheduleIDs)
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        let pendingIDs = schedules
            .filter { requestedIDs.contains($0.id) && $0.calendarExportStatus == .pending }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }

        var succeededCount = 0
        var failedCount = 0
        var unknownCount = 0
        for scheduleID in pendingIDs {
            switch await export(scheduleID: scheduleID) {
            case .succeeded, .alreadySucceeded:
                succeededCount += 1
            case .failed:
                failedCount += 1
            case .unknown, .confirmationRequired:
                unknownCount += 1
            }
        }
        return CalendarExportSummary(
            succeededCount: succeededCount,
            failedCount: failedCount,
            unknownCount: unknownCount
        )
    }

    func resumePendingExports() async throws -> CalendarExportSummary {
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        return try await exportRequested(
            scheduleIDs: schedules
                .filter { $0.calendarExportStatus == .pending }
                .map(\.id)
        )
    }

    func export(
        scheduleID: UUID,
        confirmUnknownDuplicateRisk: Bool = false
    ) async -> CalendarExportResult {
        guard var schedule = storedSchedule(id: scheduleID) else {
            return .failed(.unavailable)
        }
        if schedule.calendarExportStatus == .succeeded {
            return .alreadySucceeded
        }
        if schedule.calendarExportStatus == .unknown && !confirmUnknownDuplicateRisk {
            return .confirmationRequired
        }
        if schedule.calendarExportStatus == .exporting && !confirmUnknownDuplicateRisk {
            markUnknown(schedule)
            do {
                try save(context)
                return .confirmationRequired
            } catch {
                context.rollback()
                return .failed(.localStateSaveFailed)
            }
        }

        do {
            _ = try eventDraft(for: schedule)
        } catch {
            return finalizeClearFailure(.invalidSchedule, for: schedule)
        }

        schedule.calendarExportStatus = .exporting
        schedule.calendarEventIdentifier = nil
        schedule.calendarExportFailureMessage = nil
        do {
            try save(context)
        } catch {
            context.rollback()
            return .failed(.localStateSaveFailed)
        }

        let access: CalendarAuthorizationAccess
        do {
            access = if writer.access == .notDetermined {
                try await writer.requestWriteOnlyAccess()
            } else {
                writer.access
            }
        } catch {
            guard let current = storedSchedule(id: scheduleID),
                  current.calendarExportStatus == .exporting else { return .failed(.unavailable) }
            return finalizeClearFailure(.accessRequestFailed, for: current)
        }

        // Permission requests suspend. Another scene may delete or edit the
        // schedule while the system prompt is open. Re-read the saved intent.
        guard let current = storedSchedule(id: scheduleID),
              current.calendarExportStatus == .exporting else { return .failed(.unavailable) }
        schedule = current

        switch access {
        case .denied:
            return finalizeClearFailure(.accessDenied, for: schedule)
        case .restricted:
            return finalizeClearFailure(.accessRestricted, for: schedule)
        case .writeOnly, .fullAccess:
            break
        case .notDetermined, .unknown:
            return finalizeClearFailure(.accessRequestFailed, for: schedule)
        }

        let draft: CalendarEventDraft
        do {
            draft = try eventDraft(for: schedule)
        } catch {
            return finalizeClearFailure(.invalidSchedule, for: schedule)
        }
        let identifier: String?
        do {
            identifier = try writer.save(draft)
        } catch {
            return finalizeClearFailure(.eventSaveFailed, for: schedule)
        }

        schedule.calendarExportStatus = .succeeded
        schedule.calendarEventIdentifier = identifier
        schedule.calendarExportFailureMessage = nil
        do {
            try save(context)
            return .succeeded
        } catch {
            context.rollback()
            guard let restored = storedSchedule(id: scheduleID) else { return .unknown }
            markUnknown(restored)
            try? save(context)
            return .unknown
        }
    }

    private func storedSchedule(id: UUID) -> Schedule? {
        try? context.fetch(FetchDescriptor<Schedule>()).first { $0.id == id }
    }

    private func eventDraft(for schedule: Schedule) throws -> CalendarEventDraft {
        guard
            schedule.date.isValidGregorianDate,
            let timeZoneIdentifier = schedule.timeZoneIdentifier,
            let timeZone = TimeZone(identifier: timeZoneIdentifier)
        else {
            throw CalendarExportFailure.invalidSchedule
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start: Date
        let end: Date
        let isAllDay = schedule.time == nil
        if let time = schedule.time {
            guard
                (0..<24).contains(time.hour),
                (0..<60).contains(time.minute),
                let timedStart = calendar.date(from: DateComponents(
                    year: schedule.date.year,
                    month: schedule.date.month,
                    day: schedule.date.day,
                    hour: time.hour,
                    minute: time.minute
                )),
                let timedEnd = calendar.date(byAdding: .hour, value: 1, to: timedStart)
            else {
                throw CalendarExportFailure.invalidSchedule
            }
            start = timedStart
            end = timedEnd
        } else {
            guard
                let dayStart = calendar.date(from: DateComponents(
                    year: schedule.date.year,
                    month: schedule.date.month,
                    day: schedule.date.day
                )),
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else {
                throw CalendarExportFailure.invalidSchedule
            }
            start = dayStart
            end = nextDay
        }

        return CalendarEventDraft(
            title: schedule.title,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            timeZoneIdentifier: timeZoneIdentifier,
            alarms: []
        )
    }

    private func finalizeClearFailure(
        _ failure: CalendarExportFailure,
        for schedule: Schedule
    ) -> CalendarExportResult {
        schedule.calendarExportStatus = .failed
        schedule.calendarEventIdentifier = nil
        schedule.calendarExportFailureMessage = failure.storageMessage
        do {
            try save(context)
            return .failed(failure)
        } catch {
            context.rollback()
            guard let restored = storedSchedule(id: schedule.id) else {
                return .failed(.localStateSaveFailed)
            }
            restored.calendarExportStatus = .failed
            restored.calendarEventIdentifier = nil
            restored.calendarExportFailureMessage = CalendarExportFailure.localStateSaveFailed.storageMessage
            return .failed(.localStateSaveFailed)
        }
    }

    private func markUnknown(_ schedule: Schedule) {
        schedule.calendarExportStatus = .unknown
        schedule.calendarEventIdentifier = nil
        schedule.calendarExportFailureMessage =
            "SnapSchedule cannot tell whether Calendar finished adding this copy. Retrying may create a duplicate."
    }
}
