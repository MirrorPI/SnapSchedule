import Foundation
import Observation
import UserNotifications

@MainActor
protocol NotificationCenterScheduling {
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
}

@MainActor
final class SystemNotificationCenter: NotificationCenterScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

enum NotificationSchedulingState: Equatable, Sendable {
    case idle
    case synchronized
    case authorizationUnavailable
    case deferred
    case failed
}

struct NotificationSchedulingSummary: Equatable, Sendable {
    let state: NotificationSchedulingState
    let plannedCount: Int
    let scheduledCount: Int
    let deferredCount: Int
    let failedCount: Int

    static let idle = NotificationSchedulingSummary(
        state: .idle,
        plannedCount: 0,
        scheduledCount: 0,
        deferredCount: 0,
        failedCount: 0
    )
}

enum NotificationPayload {
    static let scheduleIDKey = "snapschedule.schedule-id"
    static let reminderKindKey = "snapschedule.reminder-kind"

    static func scheduleID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let value = userInfo[scheduleIDKey] as? String else { return nil }
        return UUID(uuidString: value)
    }
}

@MainActor
@Observable
final class NotificationScheduler {
    static let requestPrefix = "snapschedule."

    private(set) var summary: NotificationSchedulingSummary = .idle

    @ObservationIgnored private var synchronizationTail: Task<NotificationSchedulingSummary, Never>?
    @ObservationIgnored private var synchronizationGeneration = 0
    @ObservationIgnored private let center: NotificationCenterScheduling
    @ObservationIgnored private let budget: Int
    @ObservationIgnored private let now: () -> Date

    init(
        center: NotificationCenterScheduling = SystemNotificationCenter(),
        budget: Int = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.budget = max(0, budget)
        self.now = now
    }

    @discardableResult
    func synchronize(
        schedules: [Schedule],
        access: NotificationAuthorizationAccess
    ) async -> NotificationSchedulingSummary {
        synchronizationGeneration += 1
        let generation = synchronizationGeneration
        let previous = synchronizationTail
        // UserNotifications operations can suspend. Finish the previous operation before
        // a new activation or edit reads pending requests and changes them.
        let operation = Task { @MainActor in
            if let previous { _ = await previous.value }
            guard !Task.isCancelled else { return self.summary }
            return await self.performSynchronization(schedules: schedules, access: access)
        }
        synchronizationTail = operation
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if generation == synchronizationGeneration { synchronizationTail = nil }
        return result
    }

    private func performSynchronization(
        schedules: [Schedule],
        access: NotificationAuthorizationAccess
    ) async -> NotificationSchedulingSummary {
        let referenceDate = now()
        let reminders = schedules
            .flatMap { ReminderPlanner.plan(for: $0, now: referenceDate).reminders }
            .sorted {
                if $0.fireDate != $1.fireDate { return $0.fireDate < $1.fireDate }
                return $0.requestID < $1.requestID
            }
        NotificationSyncDiagnostics.record("scheduler.begin.access=\(String(describing: access)).schedules=\(schedules.count).planned=\(reminders.count)")
        let pendingBefore = await center.pendingRequests()
        guard !Task.isCancelled else { return summary }
        let ownedBefore = pendingBefore.filter { Self.owns($0.identifier) }
        NotificationSyncDiagnostics.record("pending.before.total=\(pendingBefore.count).owned=\(ownedBefore.count)")

        guard access.allowsScheduling else {
            center.removePendingRequests(withIdentifiers: ownedBefore.map(\.identifier))
            let pendingAfter = await center.pendingRequests()
            guard !Task.isCancelled else { return summary }
            NotificationSyncDiagnostics.record("pending.denied.after.owned=\(pendingAfter.filter { Self.owns($0.identifier) }.count)")
            let result = NotificationSchedulingSummary(
                state: .authorizationUnavailable,
                plannedCount: reminders.count,
                scheduledCount: 0,
                deferredCount: 0,
                failedCount: 0
            )
            summary = result
            return result
        }

        let unrelatedCount = pendingBefore.count - ownedBefore.count
        let availableSlots = max(0, budget - unrelatedCount)
        let desiredReminders = Array(reminders.prefix(availableSlots))
        let desiredByID = Dictionary(uniqueKeysWithValues: desiredReminders.map { ($0.requestID, $0) })
        let matchingIDs = Set(ownedBefore.compactMap { request -> String? in
            guard
                let reminder = desiredByID[request.identifier],
                Self.matches(request, reminder: reminder)
            else {
                return nil
            }
            return request.identifier
        })
        center.removePendingRequests(
            withIdentifiers: ownedBefore.map(\.identifier).filter { !matchingIDs.contains($0) }
        )

        for reminder in desiredReminders where !matchingIDs.contains(reminder.requestID) {
            guard !Task.isCancelled else { return summary }
            do {
                try await center.add(Self.request(for: reminder))
            } catch {
                // The verified pending list below is the source of truth.
            }
        }

        guard !Task.isCancelled else { return summary }
        let pendingAfter = await center.pendingRequests()
        guard !Task.isCancelled else { return summary }
        NotificationSyncDiagnostics.record("pending.after.total=\(pendingAfter.count).owned=\(pendingAfter.filter { Self.owns($0.identifier) }.count)")
        let verifiedCount = desiredReminders.reduce(into: 0) { count, reminder in
            guard let pending = pendingAfter.first(where: { $0.identifier == reminder.requestID }) else {
                return
            }
            if Self.matches(pending, reminder: reminder) {
                count += 1
            }
        }
        let failedCount = desiredReminders.count - verifiedCount
        let deferredCount = reminders.count - desiredReminders.count
        let state: NotificationSchedulingState
        if failedCount > 0 {
            state = .failed
        } else if deferredCount > 0 {
            state = .deferred
        } else {
            state = .synchronized
        }
        let result = NotificationSchedulingSummary(
            state: state,
            plannedCount: reminders.count,
            scheduledCount: verifiedCount,
            deferredCount: deferredCount,
            failedCount: failedCount
        )
        summary = result
        NotificationSyncDiagnostics.record("scheduler.end.\(String(describing: state)).scheduled=\(verifiedCount).deferred=\(deferredCount).failed=\(failedCount)")
        return result
    }

    static func owns(_ requestID: String) -> Bool {
        requestID.hasPrefix(requestPrefix)
    }

    static func request(for reminder: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = body(for: reminder.kind)
        content.sound = .default
        content.userInfo = [
            NotificationPayload.scheduleIDKey: reminder.scheduleID.uuidString,
            NotificationPayload.reminderKindKey: reminder.kind.rawValue
        ]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: reminder.timeZoneIdentifier) ?? .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.fireDate
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: reminder.requestID, content: content, trigger: trigger)
    }

    private static func body(for kind: ReminderKind) -> String {
        kind == .dayBefore ? String(localized: "Scheduled for tomorrow.") : String(localized: "Scheduled for today.")
    }

    private static func matches(
        _ request: UNNotificationRequest,
        reminder: PlannedReminder
    ) -> Bool {
        guard
            request.content.title == reminder.title,
            request.content.body == body(for: reminder.kind),
            NotificationPayload.scheduleID(from: request.content.userInfo) == reminder.scheduleID,
            request.content.userInfo[NotificationPayload.reminderKindKey] as? String == reminder.kind.rawValue,
            let trigger = request.trigger as? UNCalendarNotificationTrigger,
            let fireDate = trigger.nextTriggerDate()
        else {
            return false
        }
        return abs(fireDate.timeIntervalSince(reminder.fireDate)) < 1
    }
}
