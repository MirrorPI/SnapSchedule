import SwiftData
import SwiftUI

struct ScheduleEditView: View {
    @Environment(\.reportWidgetRefreshFailure) private var reportWidgetRefreshFailure
    @Environment(\.snapCompactTypography) private var compactTypography
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    let schedule: Schedule
    let notificationAuthorization: NotificationAuthorizationService
    let notificationScheduler: NotificationScheduler
    @State private var draft: ScheduleEditDraft
    @State private var errorMessage: String?
    @State private var notificationMessage: String?
    @State private var isSaving = false
    @State private var isShowingDatePicker = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isTitleFocused: Bool

    init(
        schedule: Schedule,
        notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
        notificationScheduler: NotificationScheduler = NotificationScheduler()
    ) {
        self.schedule = schedule
        self.notificationAuthorization = notificationAuthorization
        self.notificationScheduler = notificationScheduler
        _draft = State(initialValue: ScheduleEditDraft(schedule: schedule))
    }

    var body: some View {
        Form {
            Section(String(localized: "Title")) {
                TextField(String(localized: "Title"), text: $draft.title, axis: .vertical)
                    .font(compactTypography ? .headline : .title3.weight(.semibold))
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.sentences)
                    .focused($isTitleFocused)
                    .accessibilityLabel(String(localized: "Title"))
            }
            Section(String(localized: "Details")) {
                Button {
                    isShowingDatePicker = true
                } label: {
                    LabeledContent(String(localized: "Date"), value: dateText)
                        .foregroundStyle(SnapScheduleStyle.action)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(String(localized: "Date"))
                .accessibilityValue(dateText)
                .accessibilityHint(String(localized: "Choose a date, then tap Done. Save the schedule to keep your changes."))
                Toggle(String(localized: "Include time"), isOn: $draft.includesTime)
                if draft.includesTime {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Time"))
                            DatePicker(String(localized: "Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    } else {
                        DatePicker(String(localized: "Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
                    }
                    Picker(String(localized: "Time zone"), selection: $draft.timeZoneIdentifier) {
                        ForEach(timeZoneOptions, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }

            Section {
                Toggle(String(localized: "Notify one day before"), isOn: $draft.notifyDayBefore)
                Toggle(String(localized: "Notify on the day"), isOn: $draft.notifySameDay)
                if draft.notifyDayBefore || draft.notifySameDay {
                    LabeledContent(
                        String(localized: "Permission"),
                        value: notificationAuthorization.access.displayName
                    )
                    Text(notificationAuthorization.access.guidance)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Notifications"))
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if schedule.calendarExportStatus == .succeeded {
                Section {
                    Label(
                        String(localized: "Saving here will not update the copy already exported to Calendar."),
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            ScreenshotInlineSection(sourceScreenshotIdentifier: schedule.sourceAssetIdentifier)
        }
        .tint(SnapScheduleStyle.action)
        .navigationTitle(String(localized: "Edit Schedule"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $isShowingDatePicker) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent(String(localized: "Selected date"), value: dateText)
                            .accessibilityElement(children: .combine)
                        DatePicker(String(localized: "Date"), selection: dateBinding, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(SnapScheduleStyle.calendar)
                            .environment(\.calendar, Calendar(identifier: .gregorian))
                        Text(String(localized: "Choose a date, then tap Done. Save the schedule to keep your changes."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .navigationTitle(String(localized: "Choose Date"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { isShowingDatePicker = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { isTitleFocused = false }
                    .accessibilityHint(String(localized: "Dismisses the keyboard without saving."))
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) { save() }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
            }
        }
        .alert(
            String(localized: "Schedule Could Not Be Saved"),
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
            String(localized: "Schedule Saved"),
            isPresented: Binding(
                get: { notificationMessage != nil },
                set: { if !$0 { notificationMessage = nil } }
            )
        ) {
            Button(String(localized: "Done")) { dismiss() }
        } message: {
            Text(notificationMessage ?? "")
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft.date.foundationDate() ?? .now },
            set: { draft.date = CalendarDate.gregorianDate(from: $0) }
        )
    }

    private var dateText: String {
        LocalizedDateText.dateTime(
            year: draft.date.year, month: draft.date.month, day: draft.date.day,
            locale: locale
        ) ?? String(localized: "Unavailable")
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Self.date(from: draft.time) },
            set: { draft.time = Self.clockTime(from: $0) }
        )
    }

    private var timeZoneOptions: [String] {
        var identifiers = ["Asia/Seoul", "UTC", "GMT", TimeZone.current.identifier]
        identifiers.append(draft.timeZoneIdentifier)
        return identifiers.reduce(into: []) { result, identifier in
            if !result.contains(identifier) { result.append(identifier) }
        }
    }

    private func save() {
        guard !isSaving else { return }
        let turnsOnNotifications = draft.enablesNotification(comparedTo: schedule)

        do {
            let result = try ScheduleMutationService(context: modelContext).update(scheduleID: schedule.id, draft: draft)
            if result.widgetRefreshFailed { reportWidgetRefreshFailure() }
            isSaving = true
            Task { @MainActor in
                let access: NotificationAuthorizationAccess
                if turnsOnNotifications {
                    access = await notificationAuthorization
                        .requestAuthorizationIfNeeded(remindersEnabled: true)
                        .access
                } else {
                    await notificationAuthorization.refresh()
                    access = notificationAuthorization.access
                }

                guard let schedules = try? modelContext.fetch(FetchDescriptor<Schedule>()) else {
                    isSaving = false
                    notificationMessage = String(localized: "The schedule remains saved. Reminder status could not be refreshed and will be retried when the app becomes active.")
                    return
                }
                let summary = await notificationScheduler.synchronize(
                    schedules: schedules,
                    access: access
                )
                isSaving = false

                if summary.failedCount > 0 {
                    notificationMessage = String(localized: "The schedule remains saved, but \(summary.failedCount) reminders could not be scheduled and will be retried.")
                } else if summary.deferredCount > 0 {
                    notificationMessage = String(localized: "The schedule remains saved. \(summary.deferredCount) distant reminders will be scheduled after a future app activation frees capacity.")
                } else if access.allowsScheduling || (!draft.notifyDayBefore && !draft.notifySameDay) {
                    dismiss()
                } else if access == .denied {
                    notificationMessage = String(localized: "The schedule remains saved, but notification access is denied. You can enable it in Settings.")
                } else {
                    notificationMessage = String(localized: "The schedule remains saved. Notification permission is \(access.displayName); review it in Settings.")
                }
            }
        } catch ScheduleMutationError.blankTitle {
            errorMessage = String(localized: "Enter a title that is not only whitespace.")
        } catch ScheduleMutationError.invalidDate {
            errorMessage = String(localized: "Choose a valid Gregorian calendar date.")
        } catch ScheduleMutationError.invalidTime {
            errorMessage = String(localized: "Choose a valid time.")
        } catch ScheduleMutationError.invalidTimeZone {
            errorMessage = String(localized: "Choose a valid time zone.")
        } catch {
            errorMessage = String(localized: "The schedule was not changed. Please try again.")
        }
    }

    private static func date(from value: ClockTime) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: value.hour, minute: value.minute)
        ) ?? .now
    }

    private static func clockTime(from value: Date) -> ClockTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: value)
        return ClockTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }
}
