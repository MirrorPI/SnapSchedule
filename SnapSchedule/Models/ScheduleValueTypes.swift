import Foundation

struct CalendarDate: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
}

extension CalendarDate {
    var isValidGregorianDate: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let value = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: value)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    static func gregorianDate(from date: Date, timeZone: TimeZone = .current) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    func foundationDate(timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

struct ClockTime: Codable, Equatable, Sendable {
    let hour: Int
    let minute: Int
}

/// Value rows keep one photo candidate and let its dates be edited independently.
struct CandidateDateEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: CalendarDate?
    var time: ClockTime?
    var timeZoneIdentifier: String?
    var reviewReasons: [CandidateReviewReason] = []

    var isRegistrationEligible: Bool {
        guard date?.isValidGregorianDate == true,
              reviewReasons.allSatisfy({ $0 == .timeZoneInferred }) else { return false }
        if let time {
            guard (0..<24).contains(time.hour), (0..<60).contains(time.minute),
                  timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) != nil else { return false }
        }
        return timeZoneIdentifier == nil || timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) != nil
    }

    func matches(_ other: Self, fallbackZone: String) -> Bool {
        date == other.date && time == other.time
            && (timeZoneIdentifier ?? fallbackZone) == (other.timeZoneIdentifier ?? fallbackZone)
    }
}

extension Array where Element == CandidateDateEntry {
    func hasDuplicateDates(fallbackZone: String) -> Bool {
        indices.contains { index in
            prefix(index).contains { $0.matches(self[index], fallbackZone: fallbackZone) }
        }
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum ScreenshotScanStatus: String, Codable, Sendable {
    case pending
    case analyzing
    case completed
    case retryableFailure
    case inaccessible
}

enum CandidateReviewReason: String, Codable, Sendable {
    case yearInferredFromCaptureDate
    case yearInferredFromAnalysisDate
    case relativeDate
    case relativeDateBasedOnAnalysisDate
    case missingDate
    case unsupportedTimeZone
    case timeZoneInferred
    case missingTitle
    case ambiguousRange
    case ambiguousDate
    case missingTime
    case ambiguousTime
    case uncertainTimeAssociation
    case timeRangeNotStored
    case possibleMetadataDate
}

enum CandidateReviewStatus: String, Codable, Sendable {
    case pending
    case selected
    case dismissed
    case registered
}

enum CalendarExportStatus: String, Codable, Sendable {
    case notRequested
    case pending
    case exporting
    case succeeded
    case failed
    case unknown
}
