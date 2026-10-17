import SwiftUI
import WidgetKit

/// The extension and presentation checks render this same view; the provider still reads registered schedules only.
struct UpcomingScheduleWidgetContent: View {
    let family: WidgetFamily
    let plan: WidgetTimelinePlan

    var body: some View {
        Group {
            switch plan.contentState {
            case .schedules:
                if family == .systemMedium {
                    ViewThatFits(in: .vertical) {
                        mediumContent(compact: false)
                        mediumContent(compact: true)
                    }
                    .privacySensitive()
                } else if let schedule = plan.presentations.first {
                    ViewThatFits(in: .vertical) {
                        smallContent(schedule, compact: false)
                        smallContent(schedule, compact: true)
                    }
                    .privacySensitive()
                    .widgetURL(WidgetScheduleLink.url(for: schedule.id))
                }
            case .empty:
                unavailableContent(title: String(localized: "No upcoming schedules"),
                    symbol: "calendar.badge.checkmark",
                    message: String(localized: "Registered schedules will appear here."))
                    .widgetURL(WidgetScheduleLink.homeURL)
            case .unavailable:
                unavailableContent(title: String(localized: "Schedules unavailable"),
                    symbol: "exclamationmark.triangle",
                    message: String(localized: "Open SnapSchedule to refresh the widget."))
                    .widgetURL(WidgetScheduleLink.homeURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(SnapScheduleStyle.action)
        // Fixed widget surfaces keep every date and link visible. Full content is available in schedule details.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func smallContent(_ schedule: WidgetSchedulePresentation, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Label(String(localized: "Next schedule"), systemImage: "calendar")
                .font(.caption.weight(.medium)).foregroundStyle(SnapScheduleStyle.action)
                .lineLimit(1)
            Text(schedule.title)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(compact ? 2 : 3)
            Spacer(minLength: 0)
            Text(dateText(schedule))
                .font(.caption).foregroundStyle(Color.secondary)
                .lineLimit(2)
            Text(schedule.dDayText)
                .font(compact ? .headline : .title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(SnapScheduleStyle.emphasis)
                .lineLimit(1)
        }
    }

    private func mediumContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Label(String(localized: "Upcoming schedules"), systemImage: "calendar")
                .font(.caption.weight(.medium)).foregroundStyle(SnapScheduleStyle.action)
                .lineLimit(1)
            ForEach(plan.presentations.prefix(3)) { schedule in
                Link(destination: WidgetScheduleLink.url(for: schedule.id)) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.title)
                                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Text(dateText(schedule))
                                .font(compact ? .caption2 : .caption)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(schedule.dDayText)
                            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(SnapScheduleStyle.emphasis)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, compact ? 0 : 2)
                }
            }
        }
    }

    private func unavailableContent(title: String, symbol: String, message: String) -> some View {
        ViewThatFits(in: .vertical) {
            unavailableSummary(title: title, symbol: symbol, message: message, compact: false)
            unavailableSummary(title: title, symbol: symbol, message: message, compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func unavailableSummary(title: String, symbol: String, message: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Image(systemName: symbol)
                .font(compact ? .body : .title2)
                .foregroundStyle(symbol == "calendar.badge.checkmark" ? SnapScheduleStyle.action : Color.secondary)
            Text(title).font(compact ? .subheadline.weight(.semibold) : .headline)
            Text(message).font(compact ? .caption2 : .caption).foregroundStyle(Color.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dateText(_ schedule: WidgetSchedulePresentation) -> String {
        guard let text = LocalizedDateText.dateTime(
            year: schedule.date.year, month: schedule.date.month, day: schedule.date.day,
            hour: schedule.time?.hour, minute: schedule.time?.minute, dateStyle: .numeric
        ) else { return String(localized: "Date unavailable") }
        return schedule.time == nil ? String(localized: "\(text) · All-day") : text
    }

}
