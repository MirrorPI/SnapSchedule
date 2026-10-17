import SwiftData
import SwiftUI
import UIKit
import Observation

enum AppTab: Hashable { case candidates, home, settings }

/// One stable scene owner; switching tabs does not rebuild editor routes or selections.
@MainActor @Observable
final class AppTabNavigation {
    @ObservationIgnored var candidateWillLeave: (() -> Bool)?
    var tab = AppTab.home {
        didSet {
            if oldValue == .candidates, tab != oldValue, candidateWillLeave?() == false {
                tab = oldValue
            }
        }
    }
    var candidateDetailID: UUID? {
        didSet {
            guard oldValue != nil, candidateDetailID != oldValue else { return }
            if candidateWillLeave?() == false {
                candidateDetailID = oldValue
            } else {
                candidateWillLeave = nil
            }
        }
    }
    var scheduleDetailID: UUID?
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var navigation: AppTabNavigation
    private let adsConsent: AdsConsentManager
    @State private var bannerController: AdaptiveBannerController
    @State private var photoAuthorization: PhotoAuthorizationService
    @State private var notificationAuthorization: NotificationAuthorizationService
    @State private var notificationScheduler: NotificationScheduler
    @State private var candidateSelectionState: CandidateSelectionState
    @State private var presentationDate = Date.now
    @State private var deviceTimeZone = TimeZone.current
    @State private var selectedCalendarDate = CalendarDate.gregorianDate(from: .now)
    @State private var calendarRecoveryMessage: String?
    @State private var compactTypography = false
    @State private var isResumingCalendarExports = false
    @State private var notificationScheduleQueryFailed = false
    @Query private var candidates: [ScheduleCandidate]
    @Query private var schedules: [Schedule]
    let scanCoordinator: ScanCoordinator
    let notificationNavigation: NotificationNavigationStore

    init(
        scanCoordinator: ScanCoordinator,
        notificationNavigation: NotificationNavigationStore,
        notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
        notificationScheduler: NotificationScheduler = NotificationScheduler(),
        photoAuthorization: PhotoAuthorizationService = PhotoAuthorizationService(),
        adsConsent: AdsConsentManager = .shared,
        bannerController: AdaptiveBannerController? = nil,
        navigation: AppTabNavigation = AppTabNavigation(),
        candidateSelectionState: CandidateSelectionState = CandidateSelectionState()
    ) {
        _navigation = State(initialValue: navigation)
        _photoAuthorization = State(initialValue: photoAuthorization)
        _candidateSelectionState = State(initialValue: candidateSelectionState)
        self.adsConsent = adsConsent
        _bannerController = State(initialValue: bannerController ?? AdaptiveBannerController(manager: adsConsent))
        self.scanCoordinator = scanCoordinator
        self.notificationNavigation = notificationNavigation
        _notificationAuthorization = State(initialValue: notificationAuthorization)
        _notificationScheduler = State(initialValue: notificationScheduler)
    }

    private var upcomingSchedules: [ScheduleDatePresentation] {
        ScheduleDatePresentation.upcoming(
            schedules,
            now: presentationDate,
            deviceTimeZone: deviceTimeZone
        )
    }

    private var calendarOriginals: [CalendarDayOriginal] {
        HomeCalendarPresentation.originalsByDate(schedules)
    }

    private var selectedOriginalSchedules: [Schedule] {
        HomeCalendarPresentation.registeredSchedules(on: selectedCalendarDate, from: schedules)
    }

    private var selectedDateSchedules: [ScheduleDatePresentation] {
        HomeCalendarPresentation.schedules(
            on: selectedCalendarDate,
            from: schedules,
            now: presentationDate,
            deviceTimeZone: deviceTimeZone
        )
    }

    private var reviewStatus: CandidateReviewPresentation {
        CandidateReviewPresentation(candidates: candidates, isEditing: navigation.candidateDetailID != nil)
    }

    private var homeAdsEligible: Bool {
        navigation.tab == .home && scenePhase == .active && navigation.scheduleDetailID == nil
            && notificationNavigation.destination == nil
    }

    var body: some View {
        GeometryReader { geometry in
            tabContent
                .environment(\.snapCompactTypography, geometry.size.width <= 375)
                .onAppear { compactTypography = geometry.size.width <= 375 }
                .onChange(of: geometry.size.width) { _, width in compactTypography = width <= 375 }
        }
    }

    private var tabContent: some View {
        TabView(selection: $navigation.tab) {
            NavigationStack {
                CandidateListView(selectionState: candidateSelectionState,
                    onOpenCandidate: { navigation.candidateDetailID = $0 },
                    notificationAuthorization: notificationAuthorization,
                    notificationScheduler: notificationScheduler,
                    scanStatus: scanCoordinator.status, reviewPresentation: reviewStatus)
                    .navigationDestination(item: $navigation.candidateDetailID) { candidateID in
                        CandidateDetailEntryView(candidateID: candidateID,
                            notificationAuthorization: notificationAuthorization,
                            notificationScheduler: notificationScheduler, navigation: navigation)
                    }
            }
            .tabItem { Label(String(localized: "Candidate review"), systemImage: reviewStatus.symbol) }
            .badge(reviewStatus.badge(scanStatus: scanCoordinator.status))
            .tag(AppTab.candidates)

            homeTab
                .tabItem { Label(String(localized: "Home"), systemImage: "house") }
                .tag(AppTab.home)

            SettingsView(notificationAuthorization: notificationAuthorization, managesNotificationAuthorization: false,
                photoAuthorization: photoAuthorization, adsConsent: adsConsent,
                notificationScheduler: notificationScheduler,
                notificationScheduleQueryFailed: notificationScheduleQueryFailed, showsDismissButton: false)
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(navigation.tab == .candidates ? reviewStatus.color : SnapScheduleStyle.action)
        .onChange(of: navigation.tab) { _, tab in
            if tab != .home { bannerController.stop() }
            if tab == .home { routeNotificationIfNeeded() }
        }
        .onChange(of: navigation.candidateDetailID) { _, id in
            if id == nil { routeNotificationIfNeeded() }
        }
        .task {
            await resumeCalendarExports()
        }
        .task {
            refreshWidgetSnapshot()
        }
        .task {
            await scanCoordinator.activate(access: photoAuthorization.access)
        }
        .task {
            routeNotificationIfNeeded()
        }
        .task(id: scenePhase) {
            // A sheet shares this scene. Home is the single activation owner.
            guard scenePhase == .active else { return }
            await synchronizeNotificationsOnActivation()
        }
        .task {
            while !Task.isCancelled {
                refreshSchedulePresentation()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            NotificationRouteDiagnostics.record("scene.\(String(describing: newPhase))")
            NotificationSyncDiagnostics.record("home.scene.\(String(describing: newPhase))")
            if newPhase == .active {
                routeNotificationIfNeeded()
                refreshSchedulePresentation()
                refreshWidgetSnapshot()
                photoAuthorization.refresh()
                Task {
                    await resumeCalendarExports()
                    await scanCoordinator.activate(access: photoAuthorization.access)
                }
            } else {
                scanCoordinator.cancel()
            }
        }
        .onChange(of: photoAuthorization.access) { _, access in
            guard scenePhase == .active else { return }
            Task {
                await scanCoordinator.activate(access: access)
            }
        }
        .onChange(of: notificationNavigation.destination) { _, _ in
            routeNotificationIfNeeded()
        }
        .onOpenURL { url in
            routeWidgetURL(url)
        }
    }

    private var homeTab: some View {
        NavigationStack {
            Group {
                if photoAuthorization.access == .notDetermined {
                    PhotoOnboardingView(authorization: photoAuthorization)
                } else {
                    homeCalendarContent
                }
            }
            // Home has no text entry. Keyboard transitions in another tab/sheet
            // must not masquerade as a screen rotation and change the ad placement.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $navigation.scheduleDetailID) { scheduleID in
                ScheduleDetailEntryView(scheduleID: scheduleID,
                    notificationAuthorization: notificationAuthorization,
                    notificationScheduler: notificationScheduler)
            }
        }
    }

    private var homeCalendarContent: some View {
        GeometryReader { geometry in
            let layout = AdaptiveBannerLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
            VStack(spacing: 0) {
                AdaptiveBannerView(controller: bannerController, reservedHeight: layout.height)
                    .frame(width: layout.width)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("home-ad-placement")
                List {
                    Section {
                        if let calendarRecoveryMessage {
                            Label(calendarRecoveryMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        HomeCalendarView(
                            originals: calendarOriginals,
                            selectedDate: $selectedCalendarDate,
                            timeZone: deviceTimeZone
                        )
                        .frame(maxWidth: 420, minHeight: 330)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("home-calendar")
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
                        .listRowSeparator(.hidden)
                    } header: {
                        SnapSectionTitle(title: String(localized: "SnapSchedule calendar"), symbol: "calendar")
                    }

                    Section {
                        if selectedDateSchedules.isEmpty {
                            ContentUnavailableView(
                                String(localized: "No schedules on this date"),
                                systemImage: "calendar.badge.minus"
                            )
                        } else {
                            ForEach(selectedOriginalSchedules) { registered in
                                VStack(alignment: .leading, spacing: 12) {
                                    if let presentation = selectedDateSchedules.first(where: { $0.id == registered.id }) {
                                        scheduleRow(presentation)
                                    }
                                    ScreenshotLinkedOriginal(sourceScreenshotIdentifier: registered.sourceAssetIdentifier,
                                        scheduleID: registered.id, title: registered.title,
                                        onOpen: { navigation.scheduleDetailID = registered.id })
                                }
                                .padding(.vertical, 12)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selectedDateTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(String(localized: "\(selectedOriginalSchedules.count) registered schedules")
                                + " · " + String(localized: "Registration order"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .textCase(nil)
                        .accessibilityElement(children: .combine)
                    }

                    Section {
                        if upcomingSchedules.isEmpty {
                            ContentUnavailableView(
                                String(localized: "No upcoming schedules"),
                                systemImage: "calendar",
                                description: Text(String(localized: "Registered future schedules will appear here."))
                            )
                        } else {
                            ForEach(upcomingSchedules) { schedule in
                                scheduleRow(schedule)
                            }
                        }
                    } header: {
                        SnapSectionTitle(title: String(localized: "Upcoming schedules"), symbol: "clock")
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(20)
            }
            .modifier(AdaptiveBannerLifecycle(manager: adsConsent, controller: bannerController,
                eligible: homeAdsEligible, layout: layout))
            .background(AdsConsentHomeHost(manager: adsConsent, eligible: homeAdsEligible))
        }
    }

    private func synchronizeNotificationsOnActivation() async {
        NotificationSyncDiagnostics.record("home.activation.begin")
        await notificationAuthorization.refresh()
        guard !Task.isCancelled, scenePhase == .active else {
            NotificationSyncDiagnostics.record("home.activation.cancelled")
            return
        }
        do {
            // Fetch after refreshing access; do not depend on a previous SwiftUI Query snapshot.
            let storedSchedules = try modelContext.fetch(FetchDescriptor<Schedule>())
            NotificationSyncDiagnostics.record("home.scheduleQuery.count=\(storedSchedules.count).enabled=\(storedSchedules.filter { $0.notifyDayBefore || $0.notifySameDay }.count)")
            notificationScheduleQueryFailed = false
            await notificationScheduler.synchronize(
                schedules: storedSchedules, access: notificationAuthorization.access
            )
            NotificationSyncDiagnostics.record("home.activation.end")
        } catch {
            notificationScheduleQueryFailed = true
            NotificationSyncDiagnostics.record("home.scheduleQuery.failed")
        }
    }

    private func resumeCalendarExports() async {
        guard !isResumingCalendarExports else { return }
        isResumingCalendarExports = true
        defer { isResumingCalendarExports = false }
        let service = CalendarExportService(context: modelContext)
        do {
            _ = try service.recoverInterruptedExports()
        } catch {
            calendarRecoveryMessage = String(localized: "Calendar export recovery could not be saved. Open the schedule to try again.")
            return
        }
        let summary: CalendarExportSummary
        do {
            summary = try await service.resumePendingExports()
        } catch {
            calendarRecoveryMessage = String(localized: "Pending Calendar copies could not be checked. They will be retried when the app becomes active.")
            return
        }
        if summary.failedCount > 0 || summary.unknownCount > 0 {
            calendarRecoveryMessage = String(localized: "Some Calendar copies need attention. Open the schedule for details.")
        } else {
            calendarRecoveryMessage = nil
        }
    }

    private func scheduleRow(_ schedule: ScheduleDatePresentation) -> some View {
        Button {
            navigation.scheduleDetailID = schedule.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.title)
                        .font(compactTypography ? .subheadline.weight(.semibold) : .headline)

                    Text(scheduleDateText(schedule))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let timeZone = schedule.displayTimeZoneIdentifier {
                        Text(timeZone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if dynamicTypeSize.isAccessibilitySize, let dDayText = schedule.dayDisplay.dDayText {
                        dDayLabel(dDayText)
                    }
                }

                Spacer()

                if !dynamicTypeSize.isAccessibilitySize, let dDayText = schedule.dayDisplay.dDayText {
                    dDayLabel(dDayText)
                        .fixedSize()
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("schedule-detail-\(schedule.id)")
        .accessibilityHint(String(localized: "Opens schedule details"))
    }

    private func dDayLabel(_ text: String) -> some View {
        Text(text)
            .accessibilityLabel(LocalizedDateText.dDayAccessibility(text))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(SnapScheduleStyle.emphasis)
    }

    private func scheduleDateText(_ schedule: ScheduleDatePresentation) -> String {
        guard let text = LocalizedDateText.dateTime(
            year: schedule.date.year, month: schedule.date.month, day: schedule.date.day,
            hour: schedule.time?.hour, minute: schedule.time?.minute
        ) else { return String(localized: "Unavailable") }
        return schedule.time == nil ? String(localized: "\(text) · All-day") : text
    }

    private var selectedDateTitle: String {
        LocalizedDateText.dateTime(
            year: selectedCalendarDate.year, month: selectedCalendarDate.month,
            day: selectedCalendarDate.day, dateStyle: .complete
        ) ?? String(localized: "Selected date")
    }

    private func refreshSchedulePresentation() {
        presentationDate = .now
        deviceTimeZone = .current
    }

    private func refreshWidgetSnapshot() {
        guard let storedSchedules = try? modelContext.fetch(FetchDescriptor<Schedule>()) else { return }
        _ = try? WidgetSnapshotStore().write(schedules: storedSchedules)
    }

    private func routeNotificationIfNeeded() {
        guard let destination = notificationNavigation.destination else { return }
        NotificationRouteDiagnostics.record("home.route.\(String(describing: scenePhase)).schedules=\(schedules.count)")
        guard scenePhase == .active else {
            NotificationRouteDiagnostics.record("home.waitingForActivation")
            return
        }
        navigation.tab = .home
        guard navigation.tab == .home else { return }
        let scheduleExists = schedules.contains { $0.id == destination.scheduleID }
        NotificationRouteDiagnostics.record(scheduleExists ? "home.targetFound" : "home.targetUnavailable")
        navigation.scheduleDetailID = scheduleExists ? destination.scheduleID : nil
        notificationNavigation.consume()
    }

    private func routeWidgetURL(_ url: URL) {
        guard let scheduleID = WidgetScheduleLink.scheduleID(from: url),
              schedules.contains(where: { $0.id == scheduleID }) else {
            navigation.scheduleDetailID = nil
            return
        }
        // Use the same pending route so a failed draft save cannot lose a Widget link.
        notificationNavigation.open(scheduleID: scheduleID)
        routeNotificationIfNeeded()
    }
}

// Show permission guidance before the scheduling count.
struct HomeNotificationStatusView: View {
    @Environment(\.openURL) private var openURL
    let authorization: NotificationAuthorizationService
    let scheduler: NotificationScheduler
    var scheduleQueryFailed = false
    var showsPermissionActions = true

    @ViewBuilder
    var body: some View {
        let access = authorization.access
        if showsPermissionActions && access != .authorized {
            Label(access.guidance, systemImage: access.allowsScheduling ? "bell.badge" : "bell.slash")
                .foregroundStyle(access == .denied ? Color.orange : Color.secondary)
        }
        if showsPermissionActions && access.canOpenSystemSettings {
            Button(String(localized: "Open Notification Settings"), systemImage: "gear") {
                guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                openURL(url)
            }
        }
        if scheduleQueryFailed {
            Label(
                String(localized: "Scheduled reminders could not be checked. They will be retried when the app becomes active."),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        } else if access.allowsScheduling {
            notificationSchedulingStatusLabel
        }
    }

    @ViewBuilder
    private var notificationSchedulingStatusLabel: some View {
        let summary = scheduler.summary
        switch summary.state {
        case .idle:
            Label(String(localized: "Checking scheduled reminders."), systemImage: "clock")
                .foregroundStyle(.secondary)
        case .synchronized:
            Label(String(localized: "\(summary.scheduledCount) reminders scheduled."), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .authorizationUnavailable:
            Label(
                String(localized: "Notification access is unavailable. \(summary.plannedCount) reminders are not scheduled."),
                systemImage: "bell.slash"
            )
            .foregroundStyle(.orange)
        case .deferred:
            Label(
                String(localized: "\(summary.scheduledCount) reminders scheduled.") + " " + String(localized: "\(summary.deferredCount) distant reminders will be retried when the app becomes active."),
                systemImage: "clock.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
        case .failed:
            Label(
                String(localized: "\(summary.failedCount) reminders could not be scheduled and will be retried."),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        }
    }

}
