import Foundation
import SwiftData

@Model
final class Schedule {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var sourceCandidateID: UUID
    var title: String
    private var dateYear: Int
    private var dateMonth: Int
    private var dateDay: Int
    private var timeHour: Int?
    private var timeMinute: Int?
    var timeZoneIdentifier: String?
    private(set) var sourceAssetIdentifier: String
    var createdAt: Date
    var updatedAt: Date
    var notifyDayBefore: Bool
    var notifySameDay: Bool
    private var calendarExportStatusRawValue: String
    var calendarEventIdentifier: String?
    var calendarExportFailureMessage: String?

    var date: CalendarDate {
        get { CalendarDate(year: dateYear, month: dateMonth, day: dateDay) }
        set {
            dateYear = newValue.year
            dateMonth = newValue.month
            dateDay = newValue.day
        }
    }

    var time: ClockTime? {
        get {
            guard let timeHour, let timeMinute else { return nil }
            return ClockTime(hour: timeHour, minute: timeMinute)
        }
        set {
            timeHour = newValue?.hour
            timeMinute = newValue?.minute
        }
    }

    var calendarExportStatus: CalendarExportStatus {
        get { CalendarExportStatus(rawValue: calendarExportStatusRawValue) ?? .notRequested }
        set { calendarExportStatusRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        sourceCandidateID: UUID,
        title: String,
        date: CalendarDate,
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        sourceAssetIdentifier: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        notifyDayBefore: Bool = false,
        notifySameDay: Bool = false,
        calendarExportStatus: CalendarExportStatus = .notRequested,
        calendarEventIdentifier: String? = nil,
        calendarExportFailureMessage: String? = nil
    ) {
        self.id = id
        self.sourceCandidateID = sourceCandidateID
        self.title = title
        dateYear = date.year
        dateMonth = date.month
        dateDay = date.day
        timeHour = time?.hour
        timeMinute = time?.minute
        self.timeZoneIdentifier = timeZoneIdentifier
        self.sourceAssetIdentifier = sourceAssetIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notifyDayBefore = notifyDayBefore
        self.notifySameDay = notifySameDay
        calendarExportStatusRawValue = calendarExportStatus.rawValue
        self.calendarEventIdentifier = calendarEventIdentifier
        self.calendarExportFailureMessage = calendarExportFailureMessage
    }
}
