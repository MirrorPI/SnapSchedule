import SwiftUI
import WidgetKit

private struct UpcomingScheduleEntry: TimelineEntry {
    let date: Date
    let plan: WidgetTimelinePlan
}

private struct UpcomingScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingScheduleEntry {
        UpcomingScheduleEntry(date: .now, plan: Self.placeholderPlan)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingScheduleEntry) -> Void) {
        if context.isPreview {
            completion(UpcomingScheduleEntry(date: .now, plan: Self.placeholderPlan))
        } else {
            completion(entry(at: .now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingScheduleEntry>) -> Void) {
        let entry = entry(at: .now)
        let policy = entry.plan.nextRefreshDate.map(TimelineReloadPolicy.after) ?? .never
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func entry(at date: Date) -> UpcomingScheduleEntry {
        let result: WidgetSnapshotLoadResult
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetScheduleSharing.appGroupIdentifier
        ) {
            result = WidgetSnapshotFileReader.read(
                fileURL: containerURL.appending(path: WidgetScheduleSharing.fileName)
            )
        } else {
            result = .containerUnavailable
        }
        return UpcomingScheduleEntry(
            date: date,
            plan: WidgetTimelinePlanner.plan(
                loadResult: result,
                now: date,
                deviceTimeZone: .current
            )
        )
    }

    private static let placeholderPlan = WidgetTimelinePlan(
        contentState: .schedules,
        presentations: [
            WidgetSchedulePresentation(
                id: UUID(uuidString: "24000000-0000-0000-0000-000000000001")!,
                title: String(localized: "Upcoming schedule"),
                date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
                time: WidgetClockTime(hour: 10, minute: 0),
                timeZoneIdentifier: "Asia/Seoul",
                dDayText: "D-1"
            )
        ],
        nextRefreshDate: nil
    )
}

private struct UpcomingScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let plan: WidgetTimelinePlan

    var body: some View {
        UpcomingScheduleWidgetContent(family: family, plan: plan)
    }
}

@main
struct SnapScheduleUpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetScheduleLink.widgetKind,
            provider: UpcomingScheduleProvider()
        ) { entry in
            UpcomingScheduleWidgetView(plan: entry.plan)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(String(localized: "Upcoming schedules"))
        .description(String(localized: "See your nearest registered schedules and D-Day."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
