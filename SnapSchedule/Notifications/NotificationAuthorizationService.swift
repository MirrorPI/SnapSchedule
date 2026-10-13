import Observation
import OSLog
import UserNotifications

enum NotificationSyncDiagnostics {
    private static let logger = Logger(subsystem: "com.example.SnapSchedule", category: "NotificationSync")

    static func record(_ stage: String) {
        logger.info("\(stage, privacy: .public)")
        #if DEBUG
        print("[NotificationSync] \(stage)")
        #endif
    }
}

enum NotificationAuthorizationAccess: Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    init(systemStatus: UNAuthorizationStatus) {
        switch systemStatus {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }

    var allowsScheduling: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .unknown, .notDetermined, .denied:
            false
        }
    }

    var displayName: String {
        switch self {
        case .unknown:
            String(localized: "Checking")
        case .notDetermined:
            String(localized: "Not requested")
        case .denied:
            String(localized: "Denied")
        case .authorized:
            String(localized: "Allowed")
        case .provisional:
            String(localized: "Provisional")
        case .ephemeral:
            String(localized: "Temporary")
        }
    }

    var guidance: String {
        switch self {
        case .unknown:
            String(localized: "Notification permission is being checked.")
        case .notDetermined:
            String(localized: "Permission is requested after you register a schedule with notifications on.")
        case .denied:
            String(localized: "Schedules are still saved. Turn on notification access in System Settings to receive reminders.")
        case .authorized:
            String(localized: "Notification access is allowed.")
        case .provisional:
            String(localized: "Notifications are provisionally allowed and may be delivered quietly.")
        case .ephemeral:
            String(localized: "Notification access is temporarily allowed.")
        }
    }

    var canOpenSystemSettings: Bool {
        switch self {
        case .denied, .authorized, .provisional, .ephemeral:
            true
        case .unknown, .notDetermined:
            false
        }
    }
}

enum NotificationAuthorizationRequestResult: Equatable, Sendable {
    case notNeeded(NotificationAuthorizationAccess)
    case requested(NotificationAuthorizationAccess)
    case failed(NotificationAuthorizationAccess)

    var access: NotificationAuthorizationAccess {
        switch self {
        case let .notNeeded(access), let .requested(access), let .failed(access):
            access
        }
    }
}

@MainActor
@Observable
final class NotificationAuthorizationService {
    typealias StatusProvider = @MainActor () async -> UNAuthorizationStatus
    typealias AuthorizationRequester = @MainActor (UNAuthorizationOptions) async throws -> Bool

    private(set) var access: NotificationAuthorizationAccess = .unknown

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private let statusProvider: StatusProvider
    @ObservationIgnored private let authorizationRequester: AuthorizationRequester

    init(
        statusProvider: @escaping StatusProvider = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        authorizationRequester: @escaping AuthorizationRequester = { options in
            try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        }
    ) {
        self.statusProvider = statusProvider
        self.authorizationRequester = authorizationRequester
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        NotificationSyncDiagnostics.record("authorization.refresh.begin")
        let refreshedAccess = NotificationAuthorizationAccess(systemStatus: await statusProvider())
        guard generation == refreshGeneration, !Task.isCancelled else {
            NotificationSyncDiagnostics.record("authorization.refresh.obsolete")
            return
        }
        access = refreshedAccess
        NotificationSyncDiagnostics.record("authorization.refresh.end.\(String(describing: access))")
    }

    func requestAuthorizationIfNeeded(
        remindersEnabled: Bool
    ) async -> NotificationAuthorizationRequestResult {
        await refresh()

        guard remindersEnabled, access == .notDetermined else {
            return .notNeeded(access)
        }

        do {
            _ = try await authorizationRequester([.alert, .sound])
            await refresh()
            return .requested(access)
        } catch {
            await refresh()
            return .failed(access)
        }
    }
}
