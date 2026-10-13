import Observation
import OSLog
import UIKit
import UserNotifications

enum NotificationRouteDiagnostics {
    private static let logger = Logger(subsystem: "com.example.SnapSchedule", category: "NotificationRoute")

    static func record(_ stage: String) {
        logger.info("\(stage, privacy: .public)")
        #if DEBUG
        print("[NotificationRoute] \(stage)")
        #endif
    }
}

struct NotificationDestination: Equatable, Identifiable, Sendable {
    let id = UUID()
    let scheduleID: UUID
}

@MainActor
@Observable
final class NotificationNavigationStore {
    private(set) var destination: NotificationDestination?

    func receive(userInfo: [AnyHashable: Any]) {
        guard let scheduleID = NotificationPayload.scheduleID(from: userInfo) else {
            NotificationRouteDiagnostics.record("payload.invalid")
            return
        }
        open(scheduleID: scheduleID)
    }

    func open(scheduleID: UUID) {
        guard destination?.scheduleID != scheduleID else {
            NotificationRouteDiagnostics.record("destination.duplicateIgnored")
            return
        }
        NotificationRouteDiagnostics.record("destination.received")
        destination = NotificationDestination(scheduleID: scheduleID)
    }

    func consume() {
        NotificationRouteDiagnostics.record("destination.consumed")
        destination = nil
    }
}

@MainActor
final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let navigationStore = NotificationNavigationStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationRouteDiagnostics.record("delegate.installed")
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        NotificationRouteDiagnostics.record("callback.response")
        let scheduleID = NotificationPayload.scheduleID(
            from: response.notification.request.content.userInfo
        )
        // UIKit resumes state restoration from this completion. Keep both the
        // route update and completion on MainActor, including invalid payloads.
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let scheduleID else {
                NotificationRouteDiagnostics.record("callback.invalidPayload")
                return
            }
            self?.navigationStore.open(scheduleID: scheduleID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationRouteDiagnostics.record("callback.willPresent")
        return [.banner, .sound]
    }
}
