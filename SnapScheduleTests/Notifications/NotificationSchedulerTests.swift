import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import XCTest
@testable import SnapSchedule

// Existing notification test doubles without delivered fixtures have an empty inbox.
extension NotificationCenterScheduling {
    func deliveredRequests() async -> [UNNotificationRequest] { [] }
    func removeDeliveredRequests(withIdentifiers identifiers: [String]) {}
}

@MainActor
final class NotificationSchedulerTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let now = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01 00:00:00 UTC

    func testDeletingScheduleRemovesDeliveredPrivateNotificationsAndKeepsUnrelatedRequests() async {
        let schedule = makeSchedule(id: id(42), daysAfterNow: 2, notifyDayBefore: true)
        let request = NotificationScheduler.request(for: ReminderPlanner.plan(for: schedule, now: now).reminders[0])
        let unrelated = UNNotificationRequest(identifier: "unrelated", content: UNMutableNotificationContent(), trigger: nil)
        let center = InMemoryNotificationCenter()
        center.delivered = [request, unrelated]
        _ = await NotificationScheduler(center: center, now: { self.now }).synchronize(schedules: [], access: .authorized)
        XCTAssertEqual(center.delivered.map(\.identifier), ["unrelated"], "Deleting a schedule must remove its already-delivered private title")
    }

    func testEditingTitleOrDisablingRemindersRemovesObsoleteDeliveredTitles() async {
        let changed = makeSchedule(id: id(41), title: "Old private title", daysAfterNow: 2, notifyDayBefore: true)
        let disabled = makeSchedule(id: id(42), daysAfterNow: 2, notifyDayBefore: true)
        let unchanged = makeSchedule(id: id(43), daysAfterNow: 2, notifyDayBefore: true)
        let center = InMemoryNotificationCenter()
        center.delivered = [changed, disabled, unchanged].map {
            NotificationScheduler.request(for: ReminderPlanner.plan(for: $0, now: now).reminders[0])
        }
        let keptID = center.delivered[2].identifier
        changed.title = "Updated title"
        disabled.notifyDayBefore = false
        _ = await NotificationScheduler(center: center, now: { self.now }).synchronize(schedules: [changed, disabled, unchanged], access: .authorized)
        XCTAssertEqual(center.delivered.map(\.identifier), [keptID])
    }

    func testDateTimeEditsRemoveObsoleteDeliveredRemindersButKeepUnchangedHistory() async {
        let changedDate = makeSchedule(id: id(44), daysAfterNow: 2, notifySameDay: true)
        let changedTime = makeSchedule(id: id(45), daysAfterNow: 2, notifySameDay: true)
        let unchanged = makeSchedule(id: id(46), daysAfterNow: 2, notifySameDay: true)
        let center = InMemoryNotificationCenter()
        center.delivered = [changedDate, changedTime, unchanged].map {
            NotificationScheduler.request(for: ReminderPlanner.plan(for: $0, now: now).reminders[0])
        }
        let kept = center.delivered[2].identifier
        changedDate.date = CalendarDate(year: 2027, month: 2, day: 15)
        changedTime.time = ClockTime(hour: 18, minute: 30)
        // Synchronize after the original delivery time: unchanged historical
        // notifications must survive even when the future planner excludes them.
        let afterDelivery = expectedFireDate(daysAfterNow: 3)
        _ = await NotificationScheduler(center: center, now: { afterDelivery }).synchronize(
            schedules: [changedDate, changedTime, unchanged], access: .authorized)
        XCTAssertEqual(center.delivered.map(\.identifier), [kept])
    }

    func testDeniedEmptyScheduleListStillReportsUnavailableAuthorization() async {
        let scheduler = NotificationScheduler(center: InMemoryNotificationCenter(), now: { self.now })
        let summary = await scheduler.synchronize(schedules: [], access: .denied)
        XCTAssertEqual(summary.state, .authorizationUnavailable)
        XCTAssertEqual(summary.scheduledCount, 0)
    }

    func testDeniedReminderChoicesSurviveReopeningWithoutPendingRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "reminders.store")
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: url))
            context.autosaveEnabled = false
            let schedule = makeSchedule(id: id(71), daysAfterNow: 4)
            context.insert(schedule)
            try context.save()
            var draft = ScheduleEditDraft(schedule: schedule)
            draft.notifyDayBefore = true
            draft.notifySameDay = true
            _ = try ScheduleMutationService(context: context, widgetSnapshotRefresh: {})
                .update(scheduleID: schedule.id, draft: draft)
            let summary = await scheduler.synchronize(
                schedules: try context.fetch(FetchDescriptor<Schedule>()), access: .denied
            )
            XCTAssertEqual(summary.plannedCount, 2)
            XCTAssertTrue(center.pending.isEmpty)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: url))
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertTrue(schedule.notifyDayBefore)
        XCTAssertTrue(schedule.notifySameDay)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testReallowingRefillsOnlyFutureRequestsAndKeepsExistingRequest() async throws {
        var referenceDate = now
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { referenceDate })
        let schedule = makeSchedule(id: id(72), daysAfterNow: 2,
                                    notifyDayBefore: true, notifySameDay: true)
        _ = await scheduler.synchronize(schedules: [schedule], access: .denied)
        XCTAssertTrue(center.pending.isEmpty)
        referenceDate = expectedFireDate(daysAfterNow: 1).addingTimeInterval(60)
        let restored = await scheduler.synchronize(schedules: [schedule], access: .authorized)
        XCTAssertEqual(restored.plannedCount, 1)
        XCTAssertEqual(restored.scheduledCount, 1)
        XCTAssertEqual(center.pending.map(\.identifier),
                       ["snapschedule.21000000-0000-0000-0000-000000000072.same-day"])
        let request = try XCTUnwrap(center.pending.first)
        XCTAssertEqual((request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                       expectedFireDate(daysAfterNow: 2))
        center.failingIDs = [request.identifier]
        let repeated = await scheduler.synchronize(schedules: [schedule], access: .authorized)
        XCTAssertEqual(repeated.scheduledCount, 1)
        XCTAssertEqual(repeated.failedCount, 0)
        XCTAssertEqual(center.pending.count, 1)
    }

    func testHomeNotificationSectionShowsDeniedSettingsActionEvenWithNoSchedules() async throws {
        let authorization = NotificationAuthorizationService(statusProvider: { .denied })
        await authorization.refresh()
        let scheduler = NotificationScheduler(center: InMemoryNotificationCenter())
        _ = await scheduler.synchronize(schedules: [], access: .denied)
        let openedSettings = NotificationSettingsDestination()
        let controller = UIHostingController(rootView: Form {
            HomeNotificationStatusView(authorization: authorization, scheduler: scheduler)
        }.environment(\.openURL, OpenURLAction { url in
            openedSettings.url = url
            return .handled
        }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.5))
        let labels = accessibilityLabels(in: controller.view)
        XCTAssertTrue(labels.contains(String(localized: "Open Notification Settings")), "\(labels)")
        XCTAssertTrue(labels.contains(authorization.access.guidance), "\(labels)")
        XCTAssertFalse(labels.contains(String(localized: "\(0) reminders scheduled.")), "\(labels)")
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "home-notifications-denied-empty-\(Bundle.main.preferredLocalizations.first ?? "unknown")"
        attachment.lifetime = .keepAlways
        add(attachment)
        var activated = false
        visitAccessibilityObjects(in: controller.view) { object in
            if !activated, object.accessibilityLabel == String(localized: "Open Notification Settings") {
                activated = object.accessibilityActivate()
            }
        }
        XCTAssertTrue(activated)
        XCTAssertEqual(openedSettings.url?.absoluteString, UIApplication.openNotificationSettingsURLString)
    }

    func testHomeNotificationSectionShowsLimitedDeliveryBeforeScheduledCount() async throws {
        for systemStatus: UNAuthorizationStatus in [.provisional, .ephemeral] {
            let authorization = NotificationAuthorizationService(statusProvider: { systemStatus })
            await authorization.refresh()
            let scheduler = NotificationScheduler(center: InMemoryNotificationCenter())
            _ = await scheduler.synchronize(schedules: [], access: authorization.access)
            let controller = UIHostingController(rootView: Form {
                HomeNotificationStatusView(authorization: authorization, scheduler: scheduler)
            })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(0.3))
            let labels = accessibilityLabels(in: controller.view)
            guard let guidanceIndex = labels.firstIndex(of: authorization.access.guidance),
                  let countIndex = labels.firstIndex(of: String(localized: "\(0) reminders scheduled.")) else {
                XCTFail("Limited access must display guidance and the verified count: \(labels)")
                continue
            }
            XCTAssertLessThan(guidanceIndex, countIndex)
            XCTAssertTrue(labels.contains(String(localized: "Open Notification Settings")))
        }
    }

    func testHomeOnlyRefreshesRemindersOncePerActivationIncludingSettingsTab() async throws {
        let status = ActivationNotificationStatus()
        let authorization = NotificationAuthorizationService(statusProvider: {
            status.refreshCount += 1
            return status.value
        })
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let container = try SnapScheduleModelContainer.makeInMemory()
        container.mainContext.insert(makeSchedule(id: id(73), daysAfterNow: 3, notifySameDay: true))
        try container.mainContext.save()
        let coordinator = makeInactiveScanCoordinator(context: container.mainContext)
        let store = NotificationNavigationStore()
        let navigation = AppTabNavigation()
        func home(phase: ScenePhase) -> some View {
            HomeView(scanCoordinator: coordinator, notificationNavigation: store,
                     notificationAuthorization: authorization, notificationScheduler: scheduler, navigation: navigation)
                .modelContainer(container).environment(\.scenePhase, phase)
        }
        let controller = UIHostingController(rootView: home(phase: .inactive))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; coordinator.cancel() }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(status.refreshCount, 0, "Inactive Home must wait for activation.")
        controller.rootView = home(phase: .active)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(status.refreshCount, 1)
        XCTAssertTrue(center.pending.isEmpty)
        navigation.tab = .settings
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(navigation.tab, .settings)
        XCTAssertEqual(status.refreshCount, 1, "Opening the tab must not refresh the shared owner twice.")
        controller.rootView = home(phase: .background)
        try await Task.sleep(for: .seconds(0.5))
        status.value = .authorized
        controller.rootView = home(phase: .active)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(status.refreshCount, 2, "Home owns refresh even while Settings is selected.")
        XCTAssertEqual(authorization.access, .authorized)
        XCTAssertEqual(scheduler.summary.scheduledCount, 1)
        XCTAssertEqual(center.pending.count, 1)
    }

    private func makeInactiveScanCoordinator(context: ModelContext) -> ScanCoordinator {
        ScanCoordinator(context: context, settings: AppSettings(), discover: { .unavailable($0) },
                        loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible },
                        recognizeText: { _ in [] })
    }

    func testCancelledDeniedQueryCannotRemoveRemindersFromNextActivation() async {
        let center = InMemoryNotificationCenter()
        center.holdsNextPendingRead = true
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(id: id(74), daysAfterNow: 3, notifySameDay: true)
        let previousActivation = Task {
            await scheduler.synchronize(schedules: [schedule], access: .denied)
        }
        while center.pendingReadContinuation == nil { await Task.yield() }
        previousActivation.cancel()
        let nextActivation = Task {
            await scheduler.synchronize(schedules: [schedule], access: .authorized)
        }
        for _ in 0..<20 { await Task.yield() }
        center.pendingReadContinuation?.resume()
        _ = await previousActivation.value
        let restored = await nextActivation.value
        XCTAssertEqual(restored.scheduledCount, 1)
        XCTAssertEqual(scheduler.summary.state, .synchronized)
        XCTAssertEqual(center.pending.map(\.identifier),
                       ["snapschedule.21000000-0000-0000-0000-000000000074.same-day"])
    }

    func testLateAdditionCannotReplaceReminderFromNewerSynchronization() async throws {
        let center = InMemoryNotificationCenter()
        center.holdsNextAddition = true
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(id: id(75), title: "Original", daysAfterNow: 3, notifySameDay: true)
        let previousActivation = Task {
            await scheduler.synchronize(schedules: [schedule], access: .authorized)
        }
        while center.additionContinuation == nil { await Task.yield() }
        previousActivation.cancel()
        schedule.title = "Updated"
        let nextSynchronization = Task {
            await scheduler.synchronize(schedules: [schedule], access: .authorized)
        }
        for _ in 0..<20 { await Task.yield() }
        center.additionContinuation?.resume()
        _ = await previousActivation.value
        let summary = await nextSynchronization.value
        XCTAssertEqual(summary.scheduledCount, 1)
        XCTAssertEqual(scheduler.summary.state, .synchronized)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(try XCTUnwrap(center.pending.first).content.title, "Updated")
    }

    func testBudgetKeepsNearestSixtyOfFortySchedulesWithTwoReminders() async {
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, budget: 60, now: { self.now })
        let schedules = (1...40).map { offset in
            makeSchedule(
                id: id(offset),
                daysAfterNow: offset + 2,
                notifyDayBefore: true,
                notifySameDay: true
            )
        }

        let summary = await scheduler.synchronize(schedules: schedules, access: .authorized)

        XCTAssertEqual(summary.plannedCount, 80)
        XCTAssertEqual(summary.scheduledCount, 60)
        XCTAssertEqual(summary.deferredCount, 20)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(center.pending.filter { NotificationScheduler.owns($0.identifier) }.count, 60)
        XCTAssertFalse(center.pending.contains { $0.identifier.contains(id(40).uuidString) })
    }

    func testUnrelatedPendingRequestsReduceOwnedBudgetAndRemainUntouched() async {
        let center = InMemoryNotificationCenter(pending: [
            unrelatedRequest(id: "calendar.1"),
            unrelatedRequest(id: "calendar.2"),
            unrelatedRequest(id: "calendar.3")
        ])
        let scheduler = NotificationScheduler(center: center, budget: 60, now: { self.now })
        let schedules = (1...60).map { offset in
            makeSchedule(id: id(offset), daysAfterNow: offset + 1, notifySameDay: true)
        }

        let summary = await scheduler.synchronize(schedules: schedules, access: .authorized)

        XCTAssertEqual(summary.scheduledCount, 57)
        XCTAssertEqual(summary.deferredCount, 3)
        XCTAssertEqual(Set(center.pending.map(\.identifier).filter { $0.hasPrefix("calendar.") }), [
            "calendar.1", "calendar.2", "calendar.3"
        ])
    }

    func testEditReplacesContentAndTriggerAndRemovesDisabledKind() async throws {
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(
            id: id(1),
            title: "Original",
            daysAfterNow: 5,
            notifyDayBefore: true,
            notifySameDay: true
        )
        _ = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        schedule.title = "Updated"
        schedule.date = date(daysAfterNow: 8)
        schedule.notifyDayBefore = false
        let summary = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        XCTAssertEqual(summary.scheduledCount, 1)
        let request = try XCTUnwrap(center.pending.first)
        XCTAssertEqual(request.identifier, ReminderPlanner.requestID(scheduleID: schedule.id, kind: .sameDay))
        XCTAssertEqual(request.content.title, "Updated")
        XCTAssertEqual(
            (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
            expectedFireDate(daysAfterNow: 8)
        )
    }

    func testDeletionRemovesOwnedRequestsWithoutRemovingUnrelatedRequests() async {
        let unrelated = unrelatedRequest(id: "calendar.export")
        let center = InMemoryNotificationCenter(pending: [unrelated])
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(id: id(1), daysAfterNow: 5, notifySameDay: true)
        _ = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        let summary = await scheduler.synchronize(schedules: [], access: .authorized)

        XCTAssertEqual(summary.scheduledCount, 0)
        XCTAssertEqual(center.pending.map(\.identifier), ["calendar.export"])
    }

    func testDeniedAccessRemovesOwnedRequestsAndReportsUnschedulablePlans() async {
        let schedule = makeSchedule(id: id(1), daysAfterNow: 5, notifySameDay: true)
        let owned = request(for: schedule, kind: .sameDay)
        let center = InMemoryNotificationCenter(pending: [owned])
        let scheduler = NotificationScheduler(center: center, now: { self.now })

        let summary = await scheduler.synchronize(schedules: [schedule], access: .denied)

        XCTAssertEqual(summary.state, .authorizationUnavailable)
        XCTAssertEqual(summary.plannedCount, 1)
        XCTAssertEqual(summary.scheduledCount, 0)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testPendingVerificationReportsARequestSilentlyDroppedByTheSystem() async {
        let schedule = makeSchedule(id: id(1), daysAfterNow: 5, notifySameDay: true)
        let requestID = ReminderPlanner.requestID(scheduleID: schedule.id, kind: .sameDay)
        let center = InMemoryNotificationCenter(silentlyDroppedIDs: [requestID])
        let scheduler = NotificationScheduler(center: center, now: { self.now })

        let summary = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.scheduledCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
    }

    func testFailedReplacementDoesNotLeaveThePreviousReminderPending() async {
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(id: id(1), title: "Original", daysAfterNow: 5, notifySameDay: true)
        _ = await scheduler.synchronize(schedules: [schedule], access: .authorized)
        let requestID = ReminderPlanner.requestID(scheduleID: schedule.id, kind: .sameDay)

        schedule.title = "Updated"
        schedule.date = date(daysAfterNow: 8)
        center.failingIDs = [requestID]
        let summary = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertFalse(center.pending.contains { $0.identifier == requestID })
    }

    func testSynchronizationReplacesReminderWithBodyFromPreviousAppLanguage() async throws {
        let schedule = makeSchedule(id: id(1), daysAfterNow: 5, notifySameDay: true)
        let expected = request(for: schedule, kind: .sameDay)
        let content = try XCTUnwrap(expected.content.mutableCopy() as? UNMutableNotificationContent)
        content.body = "Previous-language reminder body"
        let previous = UNNotificationRequest(identifier: expected.identifier, content: content, trigger: expected.trigger)
        let center = InMemoryNotificationCenter(pending: [previous])
        let scheduler = NotificationScheduler(center: center, now: { self.now })

        let summary = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        XCTAssertEqual(summary.scheduledCount, 1)
        XCTAssertEqual(center.pending.first?.content.body, String(localized: "Scheduled for today."))
        XCTAssertEqual(center.pending.first?.identifier, expected.identifier)
    }

    func testRepeatedSynchronizationKeepsMatchingPendingRequestWithoutReaddingIt() async {
        let center = InMemoryNotificationCenter()
        let scheduler = NotificationScheduler(center: center, now: { self.now })
        let schedule = makeSchedule(id: id(1), daysAfterNow: 5, notifySameDay: true)
        _ = await scheduler.synchronize(schedules: [schedule], access: .authorized)
        let requestID = ReminderPlanner.requestID(scheduleID: schedule.id, kind: .sameDay)
        center.failingIDs = [requestID]

        let summary = await scheduler.synchronize(schedules: [schedule], access: .authorized)

        XCTAssertEqual(summary.state, .synchronized)
        XCTAssertEqual(summary.scheduledCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(center.pending.filter { $0.identifier == requestID }.count, 1)
    }

    func testNotificationPayloadAcceptsOnlyValidScheduleIdentifiers() {
        let scheduleID = id(42)

        XCTAssertEqual(
            NotificationPayload.scheduleID(from: [NotificationPayload.scheduleIDKey: scheduleID.uuidString]),
            scheduleID
        )
        XCTAssertNil(NotificationPayload.scheduleID(from: [NotificationPayload.scheduleIDKey: "not-a-uuid"]))
        XCTAssertNil(NotificationPayload.scheduleID(from: [:]))
    }

    func testNotificationNavigationStoresOnlyValidScheduleDestinationsUntilConsumed() {
        let store = NotificationNavigationStore()
        let scheduleID = id(42)

        store.receive(userInfo: [NotificationPayload.scheduleIDKey: "not-a-uuid"])
        XCTAssertNil(store.destination)

        store.receive(userInfo: [NotificationPayload.scheduleIDKey: scheduleID.uuidString])
        XCTAssertEqual(store.destination?.scheduleID, scheduleID)

        store.consume()
        XCTAssertNil(store.destination)
    }

    func testDuplicateNotificationKeepsOnePendingDestination() throws {
        let store = NotificationNavigationStore()
        store.open(scheduleID: id(42))
        let first = try XCTUnwrap(store.destination)
        store.open(scheduleID: id(42))
        XCTAssertEqual(store.destination, first)
        store.consume()
        XCTAssertNil(store.destination)
        store.open(scheduleID: id(42))
        XCTAssertEqual(store.destination?.scheduleID, id(42))
    }

    func testHomeKeepsNotificationPendingUntilSceneBecomesActive() async throws {
        let container = try makeHostingContainer()
        let context = container.mainContext
        let schedule = makeSchedule(id: id(42), daysAfterNow: 1)
        context.insert(schedule)
        try context.save()
        let store = NotificationNavigationStore()
        store.open(scheduleID: schedule.id)
        let coordinator = ScanCoordinator(
            context: context, settings: AppSettings(), discover: { .unavailable($0) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] }
        )
        let controller = UIHostingController(rootView:
            HomeView(scanCoordinator: coordinator, notificationNavigation: store)
                .modelContainer(container)
                .environment(\.scenePhase, .inactive)
        )
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            coordinator.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(store.destination?.scheduleID, schedule.id,
                       "A notification delivered before activation must remain pending.")
    }

    func testActivationRoutesPendingNotificationWithoutWaitingForScreenshotAnalysis() async throws {
        let container = try makeHostingContainer()
        let context = container.mainContext
        let schedule = makeSchedule(id: id(42), daysAfterNow: 1)
        context.insert(schedule)
        try context.save()
        let store = NotificationNavigationStore()
        store.open(scheduleID: schedule.id)
        let coordinator = ScanCoordinator(
            context: context, settings: AppSettings(), discover: { access in
                try? await Task.sleep(for: .seconds(10))
                return .unavailable(access)
            },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] }
        )
        let controller = UIHostingController(rootView:
            HomeView(scanCoordinator: coordinator, notificationNavigation: store)
                .modelContainer(container)
                .environment(\.scenePhase, .background)
        )
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            coordinator.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(store.destination?.scheduleID, schedule.id)

        controller.rootView = HomeView(scanCoordinator: coordinator, notificationNavigation: store)
            .modelContainer(container)
            .environment(\.scenePhase, .active)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(store.destination, "An unrelated analysis must not delay the notification route.")
        // The route is already consumed above. Wait for UIKit to publish its
        // rendered accessibility tree rather than inspecting a stale snapshot.
        var renderedLabels = Set<String>()
        for _ in 0..<30 {
            controller.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            renderedLabels = Set(accessibilityLabels(in: controller.view))
            if renderedLabels.contains(String(localized: "Edit")) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(renderedLabels.contains(String(localized: "Edit")), "Rendered route labels: \(renderedLabels)")
    }

    func testNotificationLeavesSettingsBeforeShowingSchedule() async throws {
        let container = try makeHostingContainer()
        let context = container.mainContext
        context.insert(makeSchedule(id: id(42), daysAfterNow: 1))
        try context.save()
        let store = NotificationNavigationStore()
        let coordinator = ScanCoordinator(
            context: context, settings: AppSettings(), discover: { .unavailable($0) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] }
        )
        let navigation = AppTabNavigation()
        let controller = UIHostingController(rootView:
            HomeView(scanCoordinator: coordinator, notificationNavigation: store, navigation: navigation)
                .modelContainer(container)
                .environment(\.scenePhase, .active)
        )
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            coordinator.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.5))
        navigation.tab = .settings
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(navigation.tab, .settings)

        store.open(scheduleID: id(42))
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(navigation.tab, .home, "Settings must not cover the requested schedule.")
        XCTAssertEqual(navigation.scheduleDetailID, id(42))
        let labelsBeforeRender = accessibilityLabels(in: controller.view)
        controller.view.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "notification-settings-to-detail"
        attachment.lifetime = .keepAlways
        add(attachment)
        let labels = accessibilityLabels(in: controller.view)
        print("Route labels before render: \(labelsBeforeRender); after render: \(labels)")
        XCTAssertTrue(labels.contains(String(localized: "Edit")), "Visible route labels: \(labels)")
    }

    func testColdHomeOpensStoredNotificationSchedule() async throws {
        try await assertHomeRoute(payload: [NotificationPayload.scheduleIDKey: id(42).uuidString],
                                  receiveBeforeLaunch: true, opensDetail: true)
    }

    func testForegroundHomeOpensNotificationScheduleWithoutDuplicateDetail() async throws {
        try await assertHomeRoute(payload: [NotificationPayload.scheduleIDKey: id(42).uuidString],
                                  receiveBeforeLaunch: false, opensDetail: true)
    }

    func testDeletedNotificationScheduleStaysOnHome() async throws {
        try await assertHomeRoute(payload: [NotificationPayload.scheduleIDKey: id(99).uuidString],
                                  receiveBeforeLaunch: true, opensDetail: false)
    }

    func testInvalidNotificationPayloadStaysOnHome() async throws {
        try await assertHomeRoute(payload: [NotificationPayload.scheduleIDKey: "not-a-uuid"],
                                  receiveBeforeLaunch: false, opensDetail: false)
    }

    private func assertHomeRoute(
        payload: [AnyHashable: Any], receiveBeforeLaunch: Bool, opensDetail: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let container = try makeHostingContainer()
        let context = container.mainContext
        context.insert(makeSchedule(id: id(42), title: "Notification route fixture", daysAfterNow: 1))
        try context.save()
        let store = NotificationNavigationStore()
        if receiveBeforeLaunch { store.receive(userInfo: payload) }
        let coordinator = ScanCoordinator(
            context: context, settings: AppSettings(), discover: { .unavailable($0) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] }
        )
        let controller = UIHostingController(rootView:
            HomeView(scanCoordinator: coordinator, notificationNavigation: store)
                .modelContainer(container)
                .environment(\.scenePhase, .active)
        )
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            coordinator.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        if !receiveBeforeLaunch {
            try await Task.sleep(for: .seconds(0.5))
            store.receive(userInfo: payload)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(store.destination, file: file, line: line)
        controller.view.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = receiveBeforeLaunch ? "notification-cold" : "notification-foreground"
        attachment.lifetime = .keepAlways
        add(attachment)
        var labels = accessibilityLabels(in: controller.view)
        if opensDetail {
            XCTAssertTrue(labels.contains(String(localized: "Edit")), "\(labels)", file: file, line: line)
            XCTAssertTrue(labels.contains { $0.contains("Notification route fixture") }, "\(labels)", file: file, line: line)
            store.receive(userInfo: payload)
            try await Task.sleep(for: .seconds(0.5))
            labels = accessibilityLabels(in: controller.view)
            XCTAssertEqual(labels.filter { $0 == String(localized: "Edit") }.count, 1, file: file, line: line)
        } else {
            XCTAssertTrue(labels.contains(String(localized: "Settings")), "\(labels)", file: file, line: line)
            XCTAssertFalse(labels.contains(String(localized: "Edit")), file: file, line: line)
        }
    }

    // Keep stores alive while SwiftUI's detached test @Query observers wind down.
    // The shipping app owns one long-lived container; each hosting test creates one.
    private static var hostingContainers: [ModelContainer] = []
    private func makeHostingContainer() throws -> ModelContainer {
        let container = try SnapScheduleModelContainer.makeInMemory()
        Self.hostingContainers.append(container)
        return container
    }

    private func accessibilityLabels(in view: UIView) -> [String] {
        var labels: [String] = []
        visitAccessibilityObjects(in: view) { object in
            if object.isAccessibilityElement {
                if let label = object.accessibilityLabel { labels.append(label) }
                if let value = object.accessibilityValue { labels.append(value) }
            }
        }
        return labels
    }

    private func visitAccessibilityObjects(in view: UIView, body: (NSObject) -> Void) {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            body(object)
            if let elements = object.accessibilityElements {
                elements.compactMap { $0 as? NSObject }.forEach(visit)
            } else {
                let count = object.accessibilityElementCount()
                if count > 0, count < 500 {
                    for index in 0..<count {
                        if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
                    }
                }
            }
            if let view = object as? UIView { view.subviews.forEach(visit) }
        }
        visit(view)
    }

    private func makeSchedule(
        id: UUID,
        title: String = "Event",
        daysAfterNow: Int,
        notifyDayBefore: Bool = false,
        notifySameDay: Bool = false
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: UUID(),
            title: title,
            date: date(daysAfterNow: daysAfterNow),
            time: ClockTime(hour: 9, minute: 0),
            timeZoneIdentifier: seoul.identifier,
            sourceAssetIdentifier: "asset-\(id.uuidString)",
            notifyDayBefore: notifyDayBefore,
            notifySameDay: notifySameDay
        )
    }

    private func date(daysAfterNow: Int) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        let value = calendar.date(byAdding: .day, value: daysAfterNow, to: now)!
        return CalendarDate.gregorianDate(from: value, timeZone: seoul)
    }

    private func expectedFireDate(daysAfterNow: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        let target = calendar.date(byAdding: .day, value: daysAfterNow, to: now)!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target)!
    }

    private func request(for schedule: Schedule, kind: ReminderKind) -> UNNotificationRequest {
        let plan = ReminderPlanner.plan(for: schedule, now: now)
        let reminder = plan.reminders.first { $0.kind == kind }!
        return NotificationScheduler.request(for: reminder)
    }

    private func unrelatedRequest(id: String) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: id,
            content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false)
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "21000000-0000-0000-0000-%012d", value))!
    }
}

@MainActor
private final class InMemoryNotificationCenter: NotificationCenterScheduling {
    private enum TestError: Error { case addFailed }

    var pending: [UNNotificationRequest]
    var delivered: [UNNotificationRequest] = []
    let silentlyDroppedIDs: Set<String>
    var failingIDs: Set<String> = []
    var holdsNextPendingRead = false
    var pendingReadContinuation: CheckedContinuation<Void, Never>?
    var holdsNextAddition = false
    var additionContinuation: CheckedContinuation<Void, Never>?

    init(
        pending: [UNNotificationRequest] = [],
        silentlyDroppedIDs: Set<String> = []
    ) {
        self.pending = pending
        self.silentlyDroppedIDs = silentlyDroppedIDs
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        if holdsNextPendingRead {
            holdsNextPendingRead = false
            await withCheckedContinuation { pendingReadContinuation = $0 }
        }
        return pending
    }

    func deliveredRequests() async -> [UNNotificationRequest] { delivered }

    func removeDeliveredRequests(withIdentifiers identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        if holdsNextAddition {
            holdsNextAddition = false
            await withCheckedContinuation { additionContinuation = $0 }
        }
        if failingIDs.contains(request.identifier) {
            throw TestError.addFailed
        }
        pending.removeAll { $0.identifier == request.identifier }
        if !silentlyDroppedIDs.contains(request.identifier) {
            pending.append(request)
        }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        let removed = Set(identifiers)
        pending.removeAll { removed.contains($0.identifier) }
    }
}

@MainActor
private final class ActivationNotificationStatus {
    var value: UNAuthorizationStatus = .denied
    var refreshCount = 0
}

@MainActor
private final class NotificationSettingsDestination {
    var url: URL?
}
