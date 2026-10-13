import Foundation

enum WidgetContentState: Equatable, Sendable {
    case schedules
    case empty
    case unavailable
}

struct WidgetSchedulePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let date: WidgetCalendarDate
    let time: WidgetClockTime?
    let timeZoneIdentifier: String
    let dDayText: String
}

struct WidgetTimelinePlan: Equatable, Sendable {
    let contentState: WidgetContentState
    let presentations: [WidgetSchedulePresentation]
    let nextRefreshDate: Date?
}

enum WidgetTimelinePlanner {
    static func plan(
        loadResult: WidgetSnapshotLoadResult,
        now: Date,
        deviceTimeZone: TimeZone
    ) -> WidgetTimelinePlan {
        let snapshots: [WidgetScheduleSnapshot]
        switch loadResult {
        case let .success(file):
            snapshots = file.schedules
        case .missing:
            return WidgetTimelinePlan(contentState: .empty, presentations: [], nextRefreshDate: nil)
        case .emptyFile, .corrupt, .unsupportedFormatVersion, .containerUnavailable:
            return WidgetTimelinePlan(contentState: .unavailable, presentations: [], nextRefreshDate: nil)
        }

        let resolved = snapshots.compactMap {
            resolve($0, now: now, deviceTimeZone: deviceTimeZone)
        }.sorted(by: comesBefore)
        let visible = Array(resolved.prefix(3))
        guard !visible.isEmpty else {
            return WidgetTimelinePlan(contentState: .empty, presentations: [], nextRefreshDate: nil)
        }

        let refreshDates = visible.flatMap { [$0.nextMidnight, $0.expirationDate] }
            .filter { $0 > now }
        return WidgetTimelinePlan(
            contentState: .schedules,
            presentations: visible.map(\.presentation),
            nextRefreshDate: refreshDates.min()
        )
    }

    private struct ResolvedSchedule {
        let presentation: WidgetSchedulePresentation
        let expirationDate: Date
        let nextMidnight: Date
    }

    private static func resolve(
        _ snapshot: WidgetScheduleSnapshot,
        now: Date,
        deviceTimeZone: TimeZone
    ) -> ResolvedSchedule? {
        let comparisonTimeZone = snapshot.time == nil
            ? deviceTimeZone
            : TimeZone(identifier: snapshot.timeZoneIdentifier) ?? deviceTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = comparisonTimeZone
        let todayStart = calendar.startOfDay(for: now)
        guard let dayStart = calendar.date(from: DateComponents(
            year: snapshot.date.year,
            month: snapshot.date.month,
            day: snapshot.date.day
        )),
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart),
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: todayStart),
        let dayDifference = calendar.dateComponents([.day], from: todayStart, to: dayStart).day else {
            return nil
        }

        let expirationDate: Date
        if let time = snapshot.time {
            guard let eventDate = calendar.date(from: DateComponents(
                year: snapshot.date.year,
                month: snapshot.date.month,
                day: snapshot.date.day,
                hour: time.hour,
                minute: time.minute
            )) else {
                return nil
            }
            expirationDate = eventDate
        } else {
            expirationDate = nextDayStart
        }
        guard expirationDate > now else { return nil }

        let dDayText = dayDifference == 0 ? "D-DAY" : "D-\(dayDifference)"
        return ResolvedSchedule(
            presentation: WidgetSchedulePresentation(
                id: snapshot.id,
                title: snapshot.title,
                date: snapshot.date,
                time: snapshot.time,
                timeZoneIdentifier: comparisonTimeZone.identifier,
                dDayText: dDayText
            ),
            expirationDate: expirationDate,
            nextMidnight: nextMidnight
        )
    }

    private static func comesBefore(_ lhs: ResolvedSchedule, _ rhs: ResolvedSchedule) -> Bool {
        let lhsDate = lhs.presentation.date
        let rhsDate = rhs.presentation.date
        if lhsDate.year != rhsDate.year { return lhsDate.year < rhsDate.year }
        if lhsDate.month != rhsDate.month { return lhsDate.month < rhsDate.month }
        if lhsDate.day != rhsDate.day { return lhsDate.day < rhsDate.day }
        switch (lhs.presentation.time, rhs.presentation.time) {
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
        return lhs.presentation.id.uuidString < rhs.presentation.id.uuidString
    }
}

enum WidgetScheduleLink {
    static let widgetKind = "SnapScheduleUpcomingWidget"
    static let homeURL = URL(string: "snapschedule://home")!
    private static let scheme = "snapschedule"
    private static let host = "schedule"

    static func url(for scheduleID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(scheduleID.uuidString)"
        return components.url!
    }

    static func scheduleID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1 else { return nil }
        return UUID(uuidString: pathComponents[0])
    }
}
