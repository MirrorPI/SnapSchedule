import Foundation

/// Formats stored Gregorian wall-clock components without DST normalization.
/// Shared by the app and Widget; user titles and OCR text never pass through it.
enum LocalizedDateText {
    static func dateTime(
        year: Int, month: Int, day: Int,
        hour: Int? = nil, minute: Int? = nil,
        locale: Locale = .current,
        dateStyle: Date.FormatStyle.DateStyle = .long
    ) -> String? {
        // This Date is a formatting coordinate, not an event instant. UTC preserves
        // user-entered clock components even if they fall in a local DST gap.
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour ?? 12, minute: minute ?? 0
        )) else { return nil }
        var format = Date.FormatStyle(
            date: dateStyle, time: hour == nil ? .omitted : .shortened,
            locale: locale, calendar: calendar, timeZone: timeZone
        )
        format.capitalizationContext = .standalone
        return date.formatted(format)
    }

    static func time(hour: Int, minute: Int, locale: Locale = .current) -> String {
        return dateTime(
            year: 2001, month: 1, day: 1, hour: hour, minute: minute,
            locale: locale, dateStyle: .omitted
        ) ?? String(localized: "Unavailable")
    }

    static func dDayAccessibility(_ text: String) -> String {
        if text == "D-DAY" { return String(localized: "Today") }
        guard text.hasPrefix("D-"), let days = Int(text.dropFirst(2)) else { return text }
        return String(localized: "\(days) days remaining")
    }
}
