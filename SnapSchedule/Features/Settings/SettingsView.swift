import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: AppSettings
    @State private var isConfirmingAnalysisErasure = false
    @State private var isErasingAnalysis = false
    @State private var analysisErasureMessage: String?
    private let eraseAnalysis: (@MainActor () async throws -> Void)?
    @State private var calendarAccess: CalendarAuthorizationAccess
    let photoAuthorization: PhotoAuthorizationService
    let adsConsent: AdsConsentManager
    private let calendarAccessProvider: @MainActor () -> CalendarAuthorizationAccess
    let notificationAuthorization: NotificationAuthorizationService
    let managesNotificationAuthorization: Bool
    let notificationScheduler: NotificationScheduler?
    let notificationScheduleQueryFailed: Bool
    let showsDismissButton: Bool

    init(
        notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
        managesNotificationAuthorization: Bool = true,
        photoAuthorization: PhotoAuthorizationService = PhotoAuthorizationService(),
        settings: AppSettings = AppSettings(),
        adsConsent: AdsConsentManager = .shared,
        calendarAccessProvider: @escaping @MainActor () -> CalendarAuthorizationAccess = { .current },
        notificationScheduler: NotificationScheduler? = nil,
        notificationScheduleQueryFailed: Bool = false,
        showsDismissButton: Bool = true,
        eraseAnalysis: (@MainActor () async throws -> Void)? = nil
    ) {
        self.notificationAuthorization = notificationAuthorization
        self.managesNotificationAuthorization = managesNotificationAuthorization
        self.notificationScheduler = notificationScheduler
        self.notificationScheduleQueryFailed = notificationScheduleQueryFailed
        self.showsDismissButton = showsDismissButton
        self.eraseAnalysis = eraseAnalysis
        self.photoAuthorization = photoAuthorization
        self.adsConsent = adsConsent
        self.calendarAccessProvider = calendarAccessProvider
        _settings = State(initialValue: settings)
        _calendarAccess = State(initialValue: calendarAccessProvider())
    }

    private var supportURL: URL {
        let path: String
        switch locale.language.languageCode?.identifier {
        case "ko": path = "/support.html"
        case "ja": path = "/ja/support.html"
        default: path = "/en/support.html"
        }
        return URL(string: "https://shottoschedule.newwren3.chatgpt.site" + path)!
    }

    private var privacyPolicyURL: URL {
        let path: String
        switch locale.language.languageCode?.identifier {
        case "ko": path = "/privacy.html"
        case "ja": path = "/ja/privacy.html"
        default: path = "/en/privacy.html"
        }
        return URL(string: "https://shottoschedule.newwren3.chatgpt.site" + path)!
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Toggle(String(localized: "Day before"), isOn: $settings.reminderDayBefore)
                    Toggle(String(localized: "Same day"), isOn: $settings.reminderSameDay)

                    LabeledContent(
                        String(localized: "Permission"),
                        value: notificationAuthorization.access.displayName
                    )

                    if notificationAuthorization.access.canOpenSystemSettings {
                        Button(String(localized: "Open Notification Settings"), systemImage: "gear") {
                            guard let url = URL(
                                string: UIApplication.openNotificationSettingsURLString
                            ) else {
                                return
                            }
                            openURL(url)
                        }
                    }
                    if let notificationScheduler {
                        HomeNotificationStatusView(
                            authorization: notificationAuthorization,
                            scheduler: notificationScheduler,
                            scheduleQueryFailed: notificationScheduleQueryFailed,
                            showsPermissionActions: false
                        )
                    }
                } header: {
                    SnapSectionTitle(title: String(localized: "Notifications"), symbol: "bell")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "These choices apply only to new candidates. Notification permission is not requested on this screen."))
                        Text(notificationAuthorization.access.guidance)
                        Text(String(localized: "Delivery can still be limited by Focus or other system notification settings."))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Toggle(String(localized: "Preselect Apple Calendar for new schedules"), isOn: $settings.defaultExportToCalendar)

                    LabeledContent(String(localized: "Permission"), value: calendarAccess.displayName)

                    if calendarAccess == .denied || calendarAccess == .restricted {
                        Button(String(localized: "Open App Settings"), systemImage: "gear") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                                return
                            }
                            openURL(url)
                        }
                    }
                } header: {
                    SnapSectionTitle(title: String(localized: "Apple Calendar"), symbol: "calendar")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "This preselects export for new candidates. Permission is requested only after registration."))
                        Text(String(localized: "Adds a separate copy to the default calendar for new events set on your iPhone. This is optional and does not sync changes from SnapSchedule."))
                        Text(String(localized: "Date-only schedules are all-day events; timed schedules last one hour. Calendar alarms, screenshots, and OCR text are never included."))
                        Text(String(localized: "Calendar copies may sync through your selected account and are not updated or deleted when you change SnapSchedule."))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    PhotoAccessView(authorization: photoAuthorization)
                } header: {
                    SnapSectionTitle(title: String(localized: "Photo access"), symbol: "photo")
                }
                if eraseAnalysis != nil {
                    Section {
                        Button(String(localized: "Delete Screenshot Analysis"), role: .destructive) {
                            isConfirmingAnalysisErasure = true
                        }
                        .disabled(isErasingAnalysis)
                        .accessibilityIdentifier("erase-screenshot-analysis")
                        if isErasingAnalysis {
                            ProgressView(String(localized: "Deleting analysis…"))
                        }
                        if let analysisErasureMessage {
                            Text(analysisErasureMessage)
                                .accessibilityIdentifier("analysis-erasure-result")
                        }
                    } header: {
                        SnapSectionTitle(title: String(localized: "Local data"), symbol: "internaldrive")
                    } footer: {
                        Text(String(localized: "Deletes extracted candidates and analysis history. Registered schedules, original photos, Calendar copies, and existing backups are kept. Older screenshots will not be analyzed again."))
                    }
                }
                Section {
                    Link(destination: supportURL) {
                        Label(String(localized: "Support"), systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("support-link")
                    Link(destination: privacyPolicyURL) {
                        Label(String(localized: "Privacy Policy"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("privacy-policy-link")
                }
                if adsConsent.privacyOptionsRequired || adsConsent.errorMessage != nil {
                    Section(String(localized: "Ad privacy")) {
                        if adsConsent.privacyOptionsRequired {
                            Button(String(localized: "Ad privacy choices")) {
                                adsConsent.presentPrivacyOptions()
                            }
                            .disabled(adsConsent.isBusy || scenePhase != .active)
                            .accessibilityIdentifier("ad-privacy-choices")
                        }
                        if let message = adsConsent.errorMessage {
                            Text(message).foregroundStyle(.secondary)
                            Button(String(localized: "Retry ad privacy update")) { adsConsent.retry() }
                                .disabled(adsConsent.isBusy || scenePhase != .active)
                        }
                    }
                }
            }
            .tint(SnapScheduleStyle.action)
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
            }
        }
        .confirmationDialog(String(localized: "Delete screenshot analysis?"),
            isPresented: $isConfirmingAnalysisErasure, titleVisibility: .visible) {
            Button(String(localized: "Delete Screenshot Analysis"), role: .destructive) {
                guard let eraseAnalysis, !isErasingAnalysis else { return }
                isErasingAnalysis = true
                analysisErasureMessage = nil
                Task { @MainActor in
                    defer { isErasingAnalysis = false }
                    do {
                        try await eraseAnalysis()
                        analysisErasureMessage = String(localized: "Screenshot analysis was deleted. Registered schedules and original photos were kept.")
                    } catch {
                        analysisErasureMessage = String(localized: "Analysis could not be deleted. Please try again.")
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This cannot be undone. Only extracted candidates and analysis history are deleted. Registered schedules, original photos, Calendar copies, and existing backups are kept."))
        }
        .task {
            if managesNotificationAuthorization {
                await notificationAuthorization.refresh()
            } else {
                NotificationSyncDiagnostics.record("settings.authorization.sharedHomeOwner")
            }
            calendarAccess = calendarAccessProvider()
            photoAuthorization.refresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            NotificationSyncDiagnostics.record("settings.scene.\(String(describing: newPhase)).ownsRefresh=\(managesNotificationAuthorization)")
            guard newPhase == .active else { return }
            calendarAccess = calendarAccessProvider()
            photoAuthorization.refresh()
            guard managesNotificationAuthorization else { return }
            Task {
                await notificationAuthorization.refresh()
            }
        }
    }
}

#Preview {
    SettingsView()
}
