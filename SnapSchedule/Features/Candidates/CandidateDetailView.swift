import Foundation
import SwiftData
import SwiftUI

enum CandidateDetailValidationError: Error, Equatable {
    case blankTitle
    case invalidDate
    case invalidTime
    case invalidTimeZone
    case duplicateDates
}

struct CandidateDateDraft: Identifiable {
    let id: UUID
    var date: CalendarDate?
    var time: ClockTime?
    var timeZoneIdentifier: String
    var confirmedReviewReasons: Set<CandidateReviewReason> = []
    let originalReviewReasons: [CandidateReviewReason]
    private let originalTimeZoneIdentifier: String

    init(entry: CandidateDateEntry) {
        id = entry.id
        date = entry.date
        time = entry.time
        timeZoneIdentifier = entry.timeZoneIdentifier ?? ""
        originalReviewReasons = entry.reviewReasons
        originalTimeZoneIdentifier = timeZoneIdentifier
    }

    var remainingReviewReasons: [CandidateReviewReason] {
        var reasons = originalReviewReasons.filter { reason in
            switch reason {
            case .missingTitle: return false // The title belongs to the candidate.
            case .missingDate: return date?.isValidGregorianDate != true
            case .missingTime: return time == nil && !confirmedReviewReasons.contains(reason)
            case .ambiguousTime: return time != nil && !confirmedReviewReasons.contains(reason)
            case .timeZoneInferred: return false
            case .unsupportedTimeZone:
                return time != nil && (TimeZone(identifier: timeZoneIdentifier) == nil
                    || (timeZoneIdentifier == originalTimeZoneIdentifier && !confirmedReviewReasons.contains(reason)))
            default: return !confirmedReviewReasons.contains(reason)
            }
        }
        if date?.isValidGregorianDate != true, !reasons.contains(.missingDate) { reasons.append(.missingDate) }
        return reasons
    }

    var isTimeZoneInferred: Bool {
        time != nil && originalReviewReasons.contains(.timeZoneInferred)
            && timeZoneIdentifier == originalTimeZoneIdentifier
    }

    var savedEntry: CandidateDateEntry {
        let remaining = remainingReviewReasons
        var reasons = originalReviewReasons.filter {
            remaining.contains($0) || ($0 == .timeZoneInferred && isTimeZoneInferred)
        }
        for reason in remaining where !reasons.contains(reason) { reasons.append(reason) }
        return CandidateDateEntry(id: id, date: date, time: time,
            timeZoneIdentifier: timeZoneIdentifier.isEmpty ? nil : timeZoneIdentifier, reviewReasons: reasons)
    }

    var isRegistrationEligible: Bool { savedEntry.isRegistrationEligible }
}

struct CandidateDetailDraft {
    var title: String
    var dateEntries: [CandidateDateDraft]
    var notifyDayBefore: Bool
    var notifySameDay: Bool
    var calendarExportRequested: Bool
    private let recognizedDateOptions: [CandidateDateEntry]

    // Keep the single-date editor API compatible with existing callers.
    var date: CalendarDate? { get { dateEntries[0].date } set { dateEntries[0].date = newValue } }
    var time: ClockTime? { get { dateEntries[0].time } set { dateEntries[0].time = newValue } }
    var timeZoneIdentifier: String {
        get { dateEntries[0].timeZoneIdentifier } set { dateEntries[0].timeZoneIdentifier = newValue }
    }
    var confirmedReviewReasons: Set<CandidateReviewReason> {
        get { dateEntries[0].confirmedReviewReasons } set { dateEntries[0].confirmedReviewReasons = newValue }
    }
    var isTimeZoneInferred: Bool { dateEntries[0].isTimeZoneInferred }

    init(candidate: ScheduleCandidate) {
        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = normalizedTitle.isEmpty || normalizedTitle == "일정 확인 필요" ? "" : candidate.title
        dateEntries = candidate.dateEntries.map(CandidateDateDraft.init)
        recognizedDateOptions = candidate.recognizedDateOptions
        notifyDayBefore = candidate.notifyDayBefore
        notifySameDay = candidate.notifySameDay
        calendarExportRequested = candidate.calendarExportRequested
    }

    mutating func addDate() {
        // Fill another recognized day without repeating a day already being edited.
        // Keep its actual time/zone and review requirements; adding is not confirmation.
        if var option = recognizedDateOptions.first(where: { option in
            option.date?.isValidGregorianDate == true
                && !dateEntries.contains { $0.date == option.date }
        }) {
            option.id = UUID()
            dateEntries.append(CandidateDateDraft(entry: option))
        } else {
            dateEntries.append(CandidateDateDraft(entry: CandidateDateEntry(timeZoneIdentifier: TimeZone.current.identifier)))
        }
    }

    mutating func removeDate(id: UUID) {
        guard dateEntries.count > 1 else { return }
        dateEntries.removeAll { $0.id == id }
    }

    var remainingReviewReasons: [CandidateReviewReason] {
        var reasons = dateEntries.flatMap(\.remainingReviewReasons)
        if !hasValidTitle { reasons.append(.missingTitle) }
        return reasons.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var hasValidTitle: Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "일정 확인 필요"
    }

    private var savedEntries: [CandidateDateEntry] {
        var entries = dateEntries.map(\.savedEntry)
        if !hasValidTitle, !entries.isEmpty { entries[0].reviewReasons.append(.missingTitle) }
        return entries
    }

    var hasDuplicateDates: Bool { savedEntries.hasDuplicateDates(fallbackZone: TimeZone.current.identifier) }
    var isRegistrationEligible: Bool {
        hasValidTitle && !dateEntries.isEmpty && dateEntries.allSatisfy(\.isRegistrationEligible) && !hasDuplicateDates
    }

    @MainActor
    mutating func save(to candidate: ScheduleCandidate, in context: ModelContext) throws {
        guard hasValidTitle else { throw CandidateDetailValidationError.blankTitle }
        guard !dateEntries.isEmpty else { throw CandidateDetailValidationError.invalidDate }
        for entry in dateEntries {
            guard entry.date?.isValidGregorianDate == true else { throw CandidateDetailValidationError.invalidDate }
            if let time = entry.time {
                guard (0..<24).contains(time.hour), (0..<60).contains(time.minute) else { throw CandidateDetailValidationError.invalidTime }
                guard TimeZone(identifier: entry.timeZoneIdentifier) != nil else { throw CandidateDetailValidationError.invalidTimeZone }
            } else if !entry.timeZoneIdentifier.isEmpty, TimeZone(identifier: entry.timeZoneIdentifier) == nil {
                throw CandidateDetailValidationError.invalidTimeZone
            }
        }
        guard !hasDuplicateDates else { throw CandidateDetailValidationError.duplicateDates }
        try ScheduleRegistrationService.requirePending(candidateID: candidate.id, in: context)
        try persist(to: candidate, in: context)
    }

    @MainActor
    func saveUnregistered(to candidate: ScheduleCandidate, in context: ModelContext,
                          save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard candidate.reviewStatus == .pending, candidate.registeredScheduleIDs.isEmpty else { return }
        try ScheduleRegistrationService.requirePending(candidateID: candidate.id, in: context)
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        guard !schedules.contains(where: { $0.sourceCandidateID == candidate.id }) else { return }
        guard differs(from: candidate) else { return }
        try persist(to: candidate, in: context, save: save)
    }

    private func differs(from candidate: ScheduleCandidate) -> Bool {
        let original = CandidateDetailDraft(candidate: candidate)
        return title.trimmingCharacters(in: .whitespacesAndNewlines) != original.title.trimmingCharacters(in: .whitespacesAndNewlines)
            || savedEntries != candidate.dateEntries
            || notifyDayBefore != candidate.notifyDayBefore || notifySameDay != candidate.notifySameDay
            || calendarExportRequested != candidate.calendarExportRequested
    }

    private func persist(to candidate: ScheduleCandidate, in context: ModelContext,
                         save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let previous = (title: candidate.title, entries: candidate.dateEntries,
            dayBefore: candidate.notifyDayBefore, sameDay: candidate.notifySameDay, export: candidate.calendarExportRequested)
        candidate.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.dateEntries = savedEntries
        candidate.notifyDayBefore = notifyDayBefore
        candidate.notifySameDay = notifySameDay
        candidate.calendarExportRequested = calendarExportRequested
        do { try save(context) } catch {
            context.rollback()
            candidate.title = previous.title
            candidate.dateEntries = previous.entries
            candidate.notifyDayBefore = previous.dayBefore
            candidate.notifySameDay = previous.sameDay
            candidate.calendarExportRequested = previous.export
            throw error
        }
    }

    /// Persist the entire review, then atomically register every prepared date.
    @MainActor
    mutating func register(to candidate: ScheduleCandidate, in context: ModelContext,
                           service: ScheduleRegistrationService? = nil) throws -> ScheduleRegistrationResult {
        guard candidate.reviewStatus == .pending, candidate.registeredScheduleIDs.isEmpty else {
            throw ScheduleRegistrationError.validationFailed([ScheduleRegistrationIssue(candidateID: candidate.id, reason: .notPending)])
        }
        try ScheduleRegistrationService.requirePending(candidateID: candidate.id, in: context)
        guard !(try context.fetch(FetchDescriptor<Schedule>())).contains(where: { $0.sourceCandidateID == candidate.id }) else {
            throw ScheduleRegistrationError.validationFailed([ScheduleRegistrationIssue(candidateID: candidate.id, reason: .alreadyRegistered)])
        }
        guard isRegistrationEligible else {
            throw ScheduleRegistrationError.validationFailed([ScheduleRegistrationIssue(candidateID: candidate.id, reason: .needsReview)])
        }
        try save(to: candidate, in: context)
        return try (service ?? ScheduleRegistrationService(context: context)).register(candidateIDs: [candidate.id])
    }

    static let suggestedTimeZoneIdentifiers = ["Asia/Seoul", "Asia/Tokyo", "America/Los_Angeles", "UTC", "GMT"]
}

struct CandidateDetailEntryView: View {
    @Query private var candidates: [ScheduleCandidate]
    let candidateID: UUID
    var notificationAuthorization = NotificationAuthorizationService()
    var notificationScheduler = NotificationScheduler()
    var navigation: AppTabNavigation?

    private var candidate: ScheduleCandidate? {
        candidates.first { $0.id == candidateID }
    }

    var body: some View {
        Group {
            if let candidate {
                CandidateDetailView(candidate: candidate, notificationAuthorization: notificationAuthorization,
                    notificationScheduler: notificationScheduler, navigation: navigation)
            } else {
                ContentUnavailableView(String(localized: "Candidate unavailable"), systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(String(localized: "Candidate"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CandidateDetailView: View {
    @Environment(\.snapCompactTypography) private var compactTypography
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let candidate: ScheduleCandidate
    @State private var draft: CandidateDetailDraft
    let notificationAuthorization: NotificationAuthorizationService
    let notificationScheduler: NotificationScheduler
    private let navigation: AppTabNavigation?
    private let draftSave: (ModelContext) throws -> Void
    @State private var isRegistering = false
    @State private var didRegister = false
    @State private var registrationFeedback: RegistrationFeedback?
    @State private var saveErrorMessage: String?
    @FocusState private var isTitleFocused: Bool

    init(candidate: ScheduleCandidate,
         notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
         notificationScheduler: NotificationScheduler = NotificationScheduler(),
         navigation: AppTabNavigation? = nil,
         draftSave: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.notificationAuthorization = notificationAuthorization
        self.notificationScheduler = notificationScheduler
        self.candidate = candidate
        self.navigation = navigation
        self.draftSave = draftSave
        _draft = State(initialValue: CandidateDetailDraft(candidate: candidate))
    }

    private var editorForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Edits are saved when you leave. Register when ready."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section(String(localized: "Title")) {
                HStack(alignment: .firstTextBaseline) {
                    TextField(String(localized: "Choose or enter a title"), text: $draft.title, axis: .vertical)
                        .lineLimit(2...6)
                        .font(compactTypography ? .headline : .title3.weight(.semibold))
                        .textInputAutocapitalization(.sentences)
                        .focused($isTitleFocused)
                        .accessibilityLabel(String(localized: "Title"))
                        .accessibilityHint(String(localized: "Choose a suggested title or enter your own."))
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { isTitleFocused = true }

                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : Array(repeating: GridItem(.flexible(minimum: 0)), count: 4), spacing: 8) {
                    ForEach(titlePresets, id: \.self) { title in
                        Button {
                            draft.title = title
                            isTitleFocused = false
                        } label: {
                            HStack(spacing: 6) {
                                Text(title)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                if draft.title == title {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                }
                            }
                                .font(dynamicTypeSize.isAccessibilitySize
                                      ? .subheadline.weight(.medium) : .footnote.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .tint(draft.title == title ? SnapScheduleStyle.action : Color.secondary)
                        .accessibilityAddTraits(draft.title == title ? .isSelected : [])
                        .accessibilityHint(String(localized: "Fills the title. You can edit it afterward."))
                    }
                }

                Button(String(localized: "Enter your own title"), systemImage: "keyboard") {
                    isTitleFocused = true
                }
            }

            Section(String(localized: "Details")) {
                ForEach($draft.dateEntries) { $entry in
                    CandidateDateEditor(entry: $entry, recognizedOptions: candidate.recognizedDateOptions,
                        number: (draft.dateEntries.firstIndex { $0.id == entry.id } ?? 0) + 1,
                        canRemove: draft.dateEntries.count > 1,
                        remove: { draft.removeDate(id: entry.id) })
                }
                Button(String(localized: "Add date +")) { draft.addDate() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("candidate-add-date")
                Text(String(localized: "\(draft.dateEntries.count) schedules to register"))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("candidate-date-count")
                if draft.hasDuplicateDates {
                    Label(String(localized: "Duplicate dates: change the date, time, or time zone, or remove a row."), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("candidate-duplicate-dates")
                }
            }

            Section {
                Toggle(String(localized: "Notify one day before"), isOn: $draft.notifyDayBefore)
                Toggle(String(localized: "Notify on the day"), isOn: $draft.notifySameDay)
            } header: {
                Text(String(localized: "Notifications"))
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(String(localized: "Add to Calendar after registration"), isOn: $draft.calendarExportRequested)
            } header: {
                Text(String(localized: "Apple Calendar"))
            } footer: {
                Text(String(localized: "Adds a separate copy to the default calendar for new events set on your iPhone. This is optional and does not sync changes from SnapSchedule."))
            }

            ScreenshotInlineSection(sourceScreenshotIdentifier: candidate.sourceAssetIdentifier)
        }
    }

    var body: some View {
        editorForm
        .tint(SnapScheduleStyle.action)
        .disabled(isRegistering || didRegister)
        .navigationBarBackButtonHidden(true)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { navigation?.candidateWillLeave = saveBeforeLeaving }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { _ = saveBeforeLeaving() }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Back"), systemImage: "chevron.backward") {
                    if saveBeforeLeaving() { dismiss() }
                }.disabled(isRegistering)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: registerCandidate) {
                    if isRegistering { ProgressView() }
                    else if draft.dateEntries.count > 1 { Text(String(localized: "Register \(draft.dateEntries.count)")) }
                    else { Text(String(localized: "Register")) }
                }
                .disabled(!draft.isRegistrationEligible || candidate.reviewStatus != .pending
                    || candidate.registeredScheduleID != nil || isRegistering || didRegister)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("candidate-register")
                    .accessibilityLabel(draft.dateEntries.count > 1
                        ? String(localized: "Register \(draft.dateEntries.count)")
                        : String(localized: "Register schedule"))
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) { isTitleFocused = false }
                    .accessibilityHint(String(localized: "Dismisses the keyboard without saving."))
            }
        }
        .alert(
            String(localized: "Candidate Could Not Be Saved"),
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? String(localized: "Please try again."))
        }
        .alert(registrationFeedback?.title ?? String(localized: "Registration"),
               isPresented: Binding(get: { registrationFeedback != nil }, set: { if !$0 { registrationFeedback = nil } })) {
            Button(String(localized: "OK")) { if didRegister { dismiss() } }
        } message: { Text(registrationFeedback?.message ?? "") }
    }

    private var titlePresets: [String] {
        [
            String(localized: "Work"),
            String(localized: "Application"),
            String(localized: "Deadline"),
            String(localized: "Gift voucher"),
            String(localized: "Ticket booking"),
            String(localized: "Event"),
            String(localized: "Reservation"),
            String(localized: "Appointment")
        ]
    }

    private func saveBeforeLeaving() -> Bool {
        guard !isRegistering else { return false }
        guard !didRegister else { return true }
        isTitleFocused = false
        do {
            try draft.saveUnregistered(to: candidate, in: modelContext, save: draftSave)
            return true
        } catch {
            saveErrorMessage = String(localized: "Your edits could not be saved. They are still here. Please try leaving again.")
            return false
        }
    }

    private func handleSaveError(_ error: Error) {
        switch error {
        case CandidateDetailValidationError.blankTitle:
            saveErrorMessage = String(localized: "Enter a title that is not only whitespace.")
        case CandidateDetailValidationError.invalidDate:
            saveErrorMessage = String(localized: "Choose a valid date.")
        case CandidateDetailValidationError.invalidTime:
            saveErrorMessage = String(localized: "Choose a valid time.")
        case CandidateDetailValidationError.invalidTimeZone:
            saveErrorMessage = String(localized: "Choose a valid time zone.")
        case CandidateDetailValidationError.duplicateDates:
            saveErrorMessage = String(localized: "Duplicate dates: change the date, time, or time zone, or remove a row.")
        default:
            saveErrorMessage = String(localized: "The change could not be saved.")
        }
    }

    private func registerCandidate() {
        guard !isRegistering, !didRegister else { return }
        isTitleFocused = false
        isRegistering = true
        let result: ScheduleRegistrationResult
        do {
            result = try draft.register(to: candidate, in: modelContext)
        } catch let error as ScheduleRegistrationError {
            isRegistering = false
            registrationFeedback = feedback(for: error)
            return
        } catch {
            isRegistering = false
            handleSaveError(error)
            return
        }
        didRegister = true
        let remindersEnabled = draft.notifyDayBefore || draft.notifySameDay

        Task { @MainActor in
            defer { isRegistering = false }
            let count = result.scheduleIDs.count
            let authorizationResult = await notificationAuthorization
                .requestAuthorizationIfNeeded(remindersEnabled: remindersEnabled)
            let schedulingSummary: NotificationSchedulingSummary?
            if let schedules = try? modelContext.fetch(FetchDescriptor<Schedule>()) {
                schedulingSummary = await notificationScheduler.synchronize(
                    schedules: schedules, access: authorizationResult.access)
            } else {
                schedulingSummary = nil
            }
            let calendarSummary = try? await CalendarExportService(context: modelContext)
                .exportRequested(scheduleIDs: result.scheduleIDs)
            registrationFeedback = RegistrationFeedback(
                title: String(localized: "Registered \(count) schedules"),
                message: registrationMessage(count: count, remindersEnabled: remindersEnabled,
                    authorizationResult: authorizationResult, schedulingSummary: schedulingSummary,
                    calendarSummary: calendarSummary))
        }
    }

    private func registrationMessage(
        count: Int,
        remindersEnabled: Bool,
        authorizationResult: NotificationAuthorizationRequestResult,
        schedulingSummary: NotificationSchedulingSummary?,
        calendarSummary: CalendarExportSummary?
    ) -> String {
        let saved = String(localized: "This candidate is now registered.")
        let reminderMessage: String
        if !remindersEnabled {
            reminderMessage = ""
        } else if let schedulingSummary {
            if schedulingSummary.failedCount > 0 {
                reminderMessage = String(localized: " \(schedulingSummary.failedCount) reminders could not be scheduled and will be retried.")
            } else if schedulingSummary.deferredCount > 0 {
                reminderMessage = String(localized: " \(schedulingSummary.deferredCount) distant reminders are waiting for a future app activation.")
            } else {
                reminderMessage = switch authorizationResult {
                case let .failed(access):
                    String(localized: " Notification permission could not be checked or requested (\(access.displayName)). Review it in Settings.")
                case let .notNeeded(access), let .requested(access):
                    if access.allowsScheduling {
                        String(localized: " Notification access is \(access.displayName).")
                    } else if access == .denied {
                        String(localized: " Notification access is denied; the schedules remain saved. You can enable it in Settings.")
                    } else {
                        String(localized: " Notification permission is still \(access.displayName). Review it in Settings.")
                    }
                }
            }
        } else {
            reminderMessage = String(localized: " Reminder status could not be refreshed; it will be retried when the app becomes active.")
        }

        let calendarMessage: String
        if let calendarSummary, calendarSummary.succeededCount > 0 {
            calendarMessage = String(localized: " \(calendarSummary.succeededCount) Calendar copies were added.")
        } else {
            calendarMessage = ""
        }
        let calendarFailureMessage = if let calendarSummary, calendarSummary.failedCount > 0 {
            String(localized: " \(calendarSummary.failedCount) Calendar copies could not be added; the internal schedules remain saved. Retry from schedule details.")
        } else {
            ""
        }
        let calendarUnknownMessage = if let calendarSummary, calendarSummary.unknownCount > 0 {
            String(localized: " Calendar completion is unknown for \(calendarSummary.unknownCount) copies; review schedule details before retrying to avoid duplicates.")
        } else {
            ""
        }

        let calendarCheckMessage = if calendarSummary == nil {
            String(localized: " Calendar copies could not be checked and will be retried when the app becomes active.")
        } else {
            ""
        }

        return saved + reminderMessage + calendarMessage + calendarFailureMessage + calendarUnknownMessage + calendarCheckMessage
    }

    private func feedback(for error: ScheduleRegistrationError) -> RegistrationFeedback {
        switch error {
        case .noSelection:
            RegistrationFeedback(
                title: String(localized: "No Candidates Selected"),
                message: String(localized: "Select at least one candidate to register.")
            )
        case .saveFailed:
            RegistrationFeedback(
                title: String(localized: "Registration Failed"),
                message: String(localized: "The schedules could not be saved. No candidates were registered. Please try again.")
            )
        case let .validationFailed(issues):
            RegistrationFeedback(
                title: String(localized: "Candidate Needs Attention"),
                message: issues.map(registrationIssueDescription).joined(separator: "\n")
            )
        }
    }

    private func registrationIssueDescription(_ issue: ScheduleRegistrationIssue) -> String {
        let title = CandidateText.displayTitle(candidate)
        let reason = switch issue.reason {
        case .unavailable:
            String(localized: "is no longer available")
        case .notPending:
            String(localized: "is no longer awaiting review")
        case .needsReview:
            String(localized: "must be corrected or confirmed")
        case .alreadyRegistered:
            String(localized: "is already registered")
        }
        return "\(title): \(reason)."
    }

}

private struct CandidateDateEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var entry: CandidateDateDraft
    let recognizedOptions: [CandidateDateEntry]
    let number: Int
    let canRemove: Bool
    let remove: () -> Void
    @State private var isSettingTime = false
    @State private var timeInput = ""
    @State private var timeInputZone = ""
    @State private var isChoosingDate = false
    @State private var isChoosingRecognizedDate = false
    @State private var chosenDate = Date.now

    var body: some View {
        Group {
            if canRemove {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Date \(number)")).font(.headline)
                        removeDateButton
                    }
                } else {
                    HStack {
                        Text(String(localized: "Date \(number)")).font(.headline)
                        Spacer()
                        removeDateButton
                    }
                }
            }
            if let date = entry.date, date.isValidGregorianDate, let value = date.foundationDate() {
                datePicker(String(localized: "Date"), selection: Binding(
                    get: { entry.date?.foundationDate() ?? value },
                    set: { entry.date = CalendarDate.gregorianDate(from: $0) }), components: .date)
            } else {
                Button(String(localized: "Choose a valid date."), systemImage: "calendar.badge.exclamationmark") {
                    chosenDate = entry.date?.foundationDate() ?? .now
                    isChoosingDate = true
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("candidate-choose-date-\(number)")
            }
            if !recognizedOptions.isEmpty {
                Button(String(localized: "Choose a recognized date")) { isChoosingRecognizedDate = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("candidate-recognized-date-\(number)")
            }
            reviewControls(for: [.yearInferredFromCaptureDate, .yearInferredFromAnalysisDate,
                .relativeDate, .relativeDateBasedOnAnalysisDate, .ambiguousRange, .ambiguousDate, .possibleMetadataDate])
            if let time = entry.time {
                if let value = Self.date(from: time) {
                    datePicker(String(localized: "Time"), selection: Binding(
                        get: { entry.time.flatMap(Self.date(from:)) ?? value },
                        set: { entry.time = Self.clockTime(from: $0) }), components: .hourAndMinute)
                } else {
                    Label(String(localized: "Choose a valid time."), systemImage: "clock.badge.exclamationmark")
                }
                reviewControls(for: [.ambiguousTime, .uncertainTimeAssociation, .timeRangeNotStored])
                Button(String(localized: "Save without a time")) { entry.time = nil }
                    .accessibilityIdentifier(number == 1 ? "candidate-remove-time" : "candidate-remove-time-\(number)")
            } else {
                LabeledContent(String(localized: "Time"), value: String(localized: "All-day"))
                Button(String(localized: "Set time")) {
                    timeInput = ""
                    timeInputZone = TimeZone(identifier: entry.timeZoneIdentifier) == nil
                        ? TimeZone.current.identifier : entry.timeZoneIdentifier
                    isSettingTime = true
                }
                .accessibilityIdentifier(number == 1 ? "candidate-set-time" : "candidate-set-time-\(number)")
                reviewControls(for: [.missingTime, .uncertainTimeAssociation, .timeRangeNotStored])
            }
            Picker(entry.isTimeZoneInferred ? String(localized: "Time zone (estimated)") : String(localized: "Time zone"), selection: $entry.timeZoneIdentifier) {
                if entry.timeZoneIdentifier.isEmpty {
                    Text(TimeZone.current.identifier).tag("")
                }
                ForEach(timeZoneOptions, id: \.self) { identifier in Text(timeZoneLabel(identifier)).tag(identifier) }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("candidate-time-zone-\(number)")
            if !entry.timeZoneIdentifier.isEmpty, TimeZone(identifier: entry.timeZoneIdentifier) == nil {
                Label(String(localized: "Choose a valid time zone."), systemImage: "exclamationmark.circle")
            }
            reviewControls(for: [.unsupportedTimeZone])
        }
        .sheet(isPresented: $isChoosingRecognizedDate) {
            NavigationStack {
                List(recognizedOptions) { option in
                    Button {
                        var selected = option
                        selected.id = entry.id
                        entry = CandidateDateDraft(entry: selected)
                        isChoosingRecognizedDate = false
                    } label: {
                        Text(optionLabel(option))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .navigationTitle(String(localized: "Choose a recognized date"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { isChoosingRecognizedDate = false }
                    }
                }
            }
        }
        .sheet(isPresented: $isChoosingDate) {
            NavigationStack {
                ScrollView {
                    DatePicker(String(localized: "Date"), selection: $chosenDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, Calendar(identifier: .gregorian))
                        .padding()
                }
                .navigationTitle(String(localized: "Date"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { isChoosingDate = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            entry.date = CalendarDate.gregorianDate(from: chosenDate)
                            isChoosingDate = false
                        }.accessibilityIdentifier("candidate-date-save")
                    }
                }
            }
        }
        .sheet(isPresented: $isSettingTime) {
            NavigationStack {
                Form {
                    Section {
                        TextField(String(localized: "Time (HH:mm)"), text: $timeInput)
                            .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker(String(localized: "Time zone"), selection: $timeInputZone) {
                            ForEach(timeZoneOptions.filter { TimeZone(identifier: $0) != nil }, id: \.self) { identifier in
                                Text(timeZoneLabel(identifier)).tag(identifier)
                            }
                        }
                    } footer: { Text(String(localized: "Enter a time from the evidence in 24-hour format, such as 14:00.")) }
                }
                .navigationTitle(String(localized: "Set time"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { isSettingTime = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save")) {
                            guard let time = enteredTime else { return }
                            entry.time = time
                            entry.timeZoneIdentifier = timeInputZone
                            entry.confirmedReviewReasons.remove(.uncertainTimeAssociation)
                            isSettingTime = false
                        }
                        .disabled(enteredTime == nil || TimeZone(identifier: timeInputZone) == nil)
                        .accessibilityIdentifier("candidate-time-save")
                    }
                }
            }
        }
    }

    private var removeDateButton: some View {
        Button(String(localized: "Remove date"), systemImage: "minus.circle", role: .destructive, action: remove)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .accessibilityIdentifier("candidate-remove-date-\(number)")
    }

    private func optionLabel(_ entry: CandidateDateEntry) -> String {
        let date = entry.date?.foundationDate()?.formatted(date: .abbreviated, time: .omitted) ?? ""
        guard let time = entry.time else { return date + " · " + String(localized: "All-day") }
        return date + String(format: " · %02d:%02d · ", time.hour, time.minute) + (entry.timeZoneIdentifier ?? "")
    }

    @ViewBuilder
    private func datePicker(_ title: String, selection: Binding<Date>, components: DatePickerComponents) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading) {
                    Text(title)
                    DatePicker(title, selection: selection, displayedComponents: components).labelsHidden()
                }
            } else { DatePicker(title, selection: selection, displayedComponents: components) }
        }
        .environment(\.calendar, Calendar(identifier: .gregorian))
        .tint(components == .date ? SnapScheduleStyle.calendar : SnapScheduleStyle.action)
    }

    @ViewBuilder
    private func reviewControls(for reasons: Set<CandidateReviewReason>) -> some View {
        ForEach(entry.originalReviewReasons.filter { reasons.contains($0) }, id: \.self) { reason in
            if reason != .unsupportedTimeZone || entry.time != nil {
                if reason == .unsupportedTimeZone, TimeZone(identifier: entry.timeZoneIdentifier) == nil {
                    Label(String(localized: "Choose a valid time zone."), systemImage: "exclamationmark.circle")
                } else if reason != .unsupportedTimeZone || entry.remainingReviewReasons.contains(reason) || entry.confirmedReviewReasons.contains(reason) {
                    Toggle(reason == .unsupportedTimeZone ? String(localized: "Confirm the selected time zone") : reason.reviewMessage,
                        isOn: Binding(get: { entry.confirmedReviewReasons.contains(reason) }, set: {
                            if $0 { entry.confirmedReviewReasons.insert(reason) } else { entry.confirmedReviewReasons.remove(reason) }
                        }))
                        .accessibilityIdentifier("candidate-review-\(reason.rawValue)")
                }
            }
        }
    }

    private var timeZoneOptions: [String] {
        var result = CandidateDetailDraft.suggestedTimeZoneIdentifiers
        for value in [TimeZone.current.identifier, entry.timeZoneIdentifier] where !value.isEmpty && !result.contains(value) { result.append(value) }
        return result
    }

    private var enteredTime: ClockTime? {
        let parts = timeInput.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return ClockTime(hour: hour, minute: minute)
    }

    private func timeZoneLabel(_ identifier: String) -> String {
        TimeZone(identifier: identifier) == nil ? String(localized: "\(identifier) (unsupported)") : identifier
    }

    private static func date(from value: ClockTime) -> Date? {
        guard (0..<24).contains(value.hour), (0..<60).contains(value.minute) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: 2001, month: 1, day: 1, hour: value.hour, minute: value.minute))
    }
    private static func clockTime(from value: Date) -> ClockTime {
        let values = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: value)
        return ClockTime(hour: values.hour!, minute: values.minute!)
    }
}

private extension CandidateReviewReason {
    var reviewMessage: String {
        switch self {
        case .yearInferredFromCaptureDate: String(localized: "Confirm the year inferred from the screenshot date")
        case .yearInferredFromAnalysisDate: String(localized: "Confirm the year inferred from the analysis date")
        case .relativeDate: String(localized: "Confirm the interpreted relative date")
        case .relativeDateBasedOnAnalysisDate: String(localized: "Confirm the relative date based on the analysis date")
        case .timeZoneInferred: String(localized: "Confirm the inferred time zone")
        case .ambiguousRange: String(localized: "Confirm the interpreted date or time range")
        case .ambiguousDate: String(localized: "Confirm the interpreted date")
        case .missingTime: String(localized: "Confirm that this event has no time")
        case .ambiguousTime: String(localized: "Confirm the interpreted time")
        case .uncertainTimeAssociation: String(localized: "Confirm the date and time pairing, or save without a time")
        case .timeRangeNotStored: String(localized: "Only the selected time is saved. Confirm that the end time and duration will not be saved.")
        case .possibleMetadataDate: String(localized: "This may be a creation date or calendar heading. Confirm it is a schedule date.")
        case .missingDate, .unsupportedTimeZone, .missingTitle: String(localized: "Review required")
        }
    }
}

private struct RegistrationFeedback {
    let title: String
    let message: String
}
