import Foundation
import SwiftData

@Model
final class ScheduleCandidate {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var sourceAssetIdentifier: String
    private(set) var sourceCandidateKey: String
    @Attribute(.unique) private var uniquenessKey: String
    var evidenceText: String?
    private var evidenceX: Double?
    private var evidenceY: Double?
    private var evidenceWidth: Double?
    private var evidenceHeight: Double?
    var title: String
    private var dateYear: Int?
    private var dateMonth: Int?
    private var dateDay: Int?
    private var timeHour: Int?
    private var timeMinute: Int?
    var timeZoneIdentifier: String?
    private var reviewReasonRawValue: String?
    var notifyDayBefore: Bool
    var notifySameDay: Bool
    var calendarExportRequested: Bool
    private var reviewStatusRawValue: String
    var registeredScheduleID: UUID?
    // Optional columns allow existing single-date stores to migrate without rewriting rows.
    private var editedDateEntriesData: Data?
    private var recognizedDateOptionsData: Data?
    private var registeredScheduleIDsRawValue: String?

    var hasEditedDateEntries: Bool { editedDateEntriesData != nil }

    var dateEntries: [CandidateDateEntry] {
        get {
            let legacy = CandidateDateEntry(id: id, date: date, time: time,
                timeZoneIdentifier: timeZoneIdentifier, reviewReasons: reviewReasons)
            guard let editedDateEntriesData else { return [legacy] }
            guard var entries = try? JSONDecoder().decode([CandidateDateEntry].self, from: editedDateEntriesData),
                  !entries.isEmpty else { return [] }
            // Keep the original scalar API usable for existing code and records.
            entries[0].date = date
            entries[0].time = time
            if time != nil { entries[0].timeZoneIdentifier = timeZoneIdentifier }
            entries[0].reviewReasons = reviewReasons
            return entries
        }
        set {
            editedDateEntriesData = try? JSONEncoder().encode(newValue)
            if let first = newValue.first {
                date = first.date
                time = first.time
                timeZoneIdentifier = first.time == nil ? nil : first.timeZoneIdentifier
                reviewReasons = first.reviewReasons
            }
        }
    }

    var recognizedDateOptions: [CandidateDateEntry] {
        get {
            guard let recognizedDateOptionsData else { return [] }
            return (try? JSONDecoder().decode([CandidateDateEntry].self, from: recognizedDateOptionsData)) ?? []
        }
        set { recognizedDateOptionsData = try? JSONEncoder().encode(newValue) }
    }

    var registeredScheduleIDs: [UUID] {
        get {
            var result = registeredScheduleID.map { [$0] } ?? []
            for value in (registeredScheduleIDsRawValue ?? "").split(separator: ",") {
                if let id = UUID(uuidString: String(value)), !result.contains(id) { result.append(id) }
            }
            return result
        }
        set {
            registeredScheduleID = newValue.first
            registeredScheduleIDsRawValue = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
        }
    }

    var evidenceLocation: NormalizedRect? {
        get {
            guard
                let evidenceX,
                let evidenceY,
                let evidenceWidth,
                let evidenceHeight
            else { return nil }
            return NormalizedRect(x: evidenceX, y: evidenceY, width: evidenceWidth, height: evidenceHeight)
        }
        set {
            evidenceX = newValue?.x
            evidenceY = newValue?.y
            evidenceWidth = newValue?.width
            evidenceHeight = newValue?.height
        }
    }

    var date: CalendarDate? {
        get {
            guard let dateYear, let dateMonth, let dateDay else { return nil }
            return CalendarDate(year: dateYear, month: dateMonth, day: dateDay)
        }
        set {
            dateYear = newValue?.year
            dateMonth = newValue?.month
            dateDay = newValue?.day
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

    var reviewReason: CandidateReviewReason? {
        get { reviewReasons.first }
        set { reviewReasons = newValue.map { [$0] } ?? [] }
    }

    var reviewReasons: [CandidateReviewReason] {
        get {
            (reviewReasonRawValue ?? "")
                .split(separator: ",")
                .compactMap { CandidateReviewReason(rawValue: String($0)) }
        }
        set {
            var seen = Set<CandidateReviewReason>()
            let rawValue = newValue
                .filter { seen.insert($0).inserted }
                .map(\.rawValue)
                .joined(separator: ",")
            reviewReasonRawValue = rawValue.isEmpty ? nil : rawValue
        }
    }

    var reviewStatus: CandidateReviewStatus {
        get { CandidateReviewStatus(rawValue: reviewStatusRawValue) ?? .pending }
        set { reviewStatusRawValue = newValue.rawValue }
    }

    var requiresReview: Bool { !isRegistrationEligible }

    var isSelectedByDefault: Bool {
        !requiresReview
    }

    var isRegistrationEligible: Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalizedTitle.isEmpty,
            normalizedTitle != "일정 확인 필요",
            !dateEntries.isEmpty,
            dateEntries.allSatisfy(\.isRegistrationEligible),
            !dateEntries.hasDuplicateDates(fallbackZone: TimeZone.current.identifier)
        else { return false }

        return true
    }

    init(
        id: UUID = UUID(),
        sourceAssetIdentifier: String,
        sourceCandidateKey: String,
        evidenceText: String? = nil,
        evidenceLocation: NormalizedRect? = nil,
        title: String,
        date: CalendarDate? = nil,
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        reviewReason: CandidateReviewReason? = nil,
        reviewReasons: [CandidateReviewReason] = [],
        notifyDayBefore: Bool = false,
        notifySameDay: Bool = false,
        calendarExportRequested: Bool = false,
        reviewStatus: CandidateReviewStatus = .pending,
        registeredScheduleID: UUID? = nil
    ) {
        self.id = id
        self.sourceAssetIdentifier = sourceAssetIdentifier
        self.sourceCandidateKey = sourceCandidateKey
        uniquenessKey = Self.makeUniquenessKey(assetIdentifier: sourceAssetIdentifier, candidateKey: sourceCandidateKey)
        self.evidenceText = evidenceText
        evidenceX = evidenceLocation?.x
        evidenceY = evidenceLocation?.y
        evidenceWidth = evidenceLocation?.width
        evidenceHeight = evidenceLocation?.height
        self.title = title
        dateYear = date?.year
        dateMonth = date?.month
        dateDay = date?.day
        timeHour = time?.hour
        timeMinute = time?.minute
        self.timeZoneIdentifier = if time != nil && timeZoneIdentifier == nil {
            TimeZone.current.identifier
        } else {
            timeZoneIdentifier
        }
        var reasons = reviewReasons.isEmpty ? reviewReason.map { [$0] } ?? [] : reviewReasons
        if time != nil, timeZoneIdentifier == nil, !reasons.contains(.timeZoneInferred) {
            reasons.append(.timeZoneInferred)
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if (normalizedTitle.isEmpty || normalizedTitle == "일정 확인 필요"), !reasons.contains(.missingTitle) {
            reasons.append(.missingTitle)
        }
        reviewReasonRawValue = reasons.isEmpty ? nil : reasons.map(\.rawValue).joined(separator: ",")
        self.notifyDayBefore = notifyDayBefore
        self.notifySameDay = notifySameDay
        self.calendarExportRequested = calendarExportRequested
        reviewStatusRawValue = reviewStatus.rawValue
        self.registeredScheduleID = registeredScheduleID
    }

    private static func makeUniquenessKey(assetIdentifier: String, candidateKey: String) -> String {
        "\(assetIdentifier.utf8.count):\(assetIdentifier)\(candidateKey)"
    }

    private var hasValidDate: Bool {
        date?.isValidGregorianDate == true
    }
}
