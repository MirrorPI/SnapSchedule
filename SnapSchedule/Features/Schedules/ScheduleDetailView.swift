import SwiftData
import SwiftUI

struct ScheduleDetailEntryView: View {
    @Query private var schedules: [Schedule]
    let scheduleID: UUID
    let notificationAuthorization: NotificationAuthorizationService
    let notificationScheduler: NotificationScheduler

    init(
        scheduleID: UUID,
        notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
        notificationScheduler: NotificationScheduler = NotificationScheduler()
    ) {
        self.scheduleID = scheduleID
        self.notificationAuthorization = notificationAuthorization
        self.notificationScheduler = notificationScheduler
    }

    private var schedule: Schedule? {
        schedules.first { $0.id == scheduleID }
    }

    var body: some View {
        Group {
            if let schedule {
                ScheduleDetailView(
                    schedule: schedule,
                    notificationAuthorization: notificationAuthorization,
                    notificationScheduler: notificationScheduler
                )
            } else {
                ContentUnavailableView(String(localized: "Schedule unavailable"), systemImage: "calendar.badge.exclamationmark")
            }
        }
        .onAppear {
            NotificationRouteDiagnostics.record(schedule == nil ? "detail.unavailable" : "detail.shown")
        }
        .navigationTitle(String(localized: "Schedule"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ScheduleDetailView: View {
    @Environment(\.snapCompactTypography) private var compactTypography
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let schedule: Schedule
    let notificationAuthorization: NotificationAuthorizationService
    let notificationScheduler: NotificationScheduler
    @State private var isEditing = false
    @State private var isConfirmingDeletion = false
    @State private var isConfirmingUnknownCalendarRetry = false
    @State private var isExportingCalendar = false
    @State private var calendarFeedback: CalendarFeedback?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Title"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(schedule.title)
                        .font(compactTypography ? .title2.weight(.semibold) : .title.weight(.semibold))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
            }
            Section(String(localized: "Details")) {
                LabeledContent(String(localized: "Date"), value: dateText)
                LabeledContent(String(localized: "Time"), value: timeText)
                if let timeZoneIdentifier = schedule.timeZoneIdentifier {
                    LabeledContent(String(localized: "Time zone"), value: timeZoneIdentifier)
                }
            }

            Section {
                LabeledContent(String(localized: "One day before"), value: schedule.notifyDayBefore ? String(localized: "On") : String(localized: "Off"))
                LabeledContent(String(localized: "On the day"), value: schedule.notifySameDay ? String(localized: "On") : String(localized: "Off"))
            } header: {
                Text(String(localized: "Notifications"))
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(String(localized: "Calendar copy")) {
                switch schedule.calendarExportStatus {
                case .notRequested:
                    Label(String(localized: "Not added"), systemImage: "calendar.badge.plus")
                        .foregroundStyle(.secondary)
                    calendarExportButton(String(localized: "Add to Calendar"))
                case .pending:
                    Label(String(localized: "Ready to add"), systemImage: "calendar.badge.plus")
                        .foregroundStyle(.secondary)
                    calendarExportButton(String(localized: "Continue Adding to Calendar"))
                case .exporting:
                    Label(String(localized: "Calendar result needs review"), systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    calendarExportButton(String(localized: "Review Calendar Status"))
                case .succeeded:
                    Label(String(localized: "Added to Calendar"), systemImage: "checkmark.circle")
                        .foregroundStyle(SnapScheduleStyle.action)
                case .failed:
                    Label(
                        localizedCalendarFailureMessage ?? String(localized: "The Calendar copy could not be added."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    calendarExportButton(String(localized: "Try Again"))
                case .unknown:
                    Label(
                        localizedCalendarFailureMessage
                            ?? String(localized: "It is unknown whether Calendar added this copy. Retrying may create a duplicate."),
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                    Button(String(localized: "Retry Anyway"), systemImage: "arrow.clockwise") {
                        isConfirmingUnknownCalendarRetry = true
                    }
                }

                Text(String(localized: "Adds a separate copy to the default calendar for new events set on your iPhone. This is optional and does not sync changes from SnapSchedule."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(String(localized: "Date-only schedules are added as all-day events. Timed schedules last one hour. No Calendar alarms, screenshot, or OCR text are included."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(String(localized: "This is a one-way copy that may sync through your Calendar account. Changes or deletion in SnapSchedule do not update or remove it."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(String(localized: "Delete Schedule"), systemImage: "trash", role: .destructive) {
                    isConfirmingDeletion = true
                }
            }

            ScreenshotInlineSection(sourceScreenshotIdentifier: schedule.sourceAssetIdentifier)
        }
        .tint(SnapScheduleStyle.action)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Edit")) { isEditing = true }
                    .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                ScheduleEditView(
                    schedule: schedule,
                    notificationAuthorization: notificationAuthorization,
                    notificationScheduler: notificationScheduler
                )
            }
        }
        .confirmationDialog(
            String(localized: "Retry Calendar export?"),
            isPresented: $isConfirmingUnknownCalendarRetry,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Retry and Accept Duplicate Risk")) {
                exportToCalendar(confirmUnknownDuplicateRisk: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Calendar may already contain the earlier copy. SnapSchedule has write-only access and cannot search for it, so retrying can create a duplicate."))
        }
        .confirmationDialog(
            String(localized: "Delete this schedule?"),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Schedule"), role: .destructive) { deleteSchedule() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            if schedule.calendarExportStatus == .succeeded {
                Text(String(localized: "The local schedule will be deleted. Its exported Calendar copy will remain."))
            } else {
                Text(String(localized: "The source screenshot and analysis history will remain."))
            }
        }
        .alert(
            String(localized: "Schedule Could Not Be Deleted"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? String(localized: "Please try again."))
        }
        .alert(
            calendarFeedback?.title ?? String(localized: "Apple Calendar"),
            isPresented: Binding(
                get: { calendarFeedback != nil },
                set: { if !$0 { calendarFeedback = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(calendarFeedback?.message ?? "")
        }
    }

    private var localizedCalendarFailureMessage: String? {
        schedule.calendarExportFailureMessage.map { String(localized: String.LocalizationValue($0)) }
    }

    private var dateText: String {
        LocalizedDateText.dateTime(
            year: schedule.date.year, month: schedule.date.month, day: schedule.date.day
        ) ?? String(localized: "Unavailable")
    }

    private var timeText: String {
        guard let time = schedule.time else { return String(localized: "All-day") }
        return LocalizedDateText.time(hour: time.hour, minute: time.minute)
    }

    private func deleteSchedule() {
        do {
            _ = try ScheduleMutationService(context: modelContext).delete(scheduleID: schedule.id)
            Task { @MainActor in
                if let schedules = try? modelContext.fetch(FetchDescriptor<Schedule>()) {
                    await notificationScheduler.synchronize(
                        schedules: schedules,
                        access: notificationAuthorization.access
                    )
                }
                dismiss()
            }
        } catch {
            errorMessage = String(localized: "The schedule was not changed. Please try again.")
        }
    }

    @ViewBuilder
    private func calendarExportButton(_ title: String) -> some View {
        Button(title, systemImage: "calendar.badge.plus") {
            exportToCalendar()
        }
        .disabled(isExportingCalendar)
    }

    private func exportToCalendar(confirmUnknownDuplicateRisk: Bool = false) {
        guard !isExportingCalendar else { return }
        isExportingCalendar = true
        Task { @MainActor in
            defer { isExportingCalendar = false }
            let result = await CalendarExportService(context: modelContext).export(
                scheduleID: schedule.id,
                confirmUnknownDuplicateRisk: confirmUnknownDuplicateRisk
            )
            if result == .confirmationRequired {
                isConfirmingUnknownCalendarRetry = true
                return
            }
            calendarFeedback = switch result {
            case .succeeded:
                CalendarFeedback(
                    title: String(localized: "Added to Calendar"),
                    message: String(localized: "A one-way copy was added without Calendar alarms.")
                )
            case .alreadySucceeded:
                CalendarFeedback(
                    title: String(localized: "Already Added"),
                    message: String(localized: "SnapSchedule did not create another Calendar copy.")
                )
            case .confirmationRequired:
                nil
            case let .failed(failure):
                CalendarFeedback(title: String(localized: "Calendar Copy Not Added"), message: failure.message)
            case .unknown:
                CalendarFeedback(
                    title: String(localized: "Calendar Result Unknown"),
                    message: String(localized: "Calendar may have added the copy. Review this status before retrying because a retry can create a duplicate.")
                )
            }
        }
    }
}

private struct CalendarFeedback {
    let title: String
    let message: String
}
