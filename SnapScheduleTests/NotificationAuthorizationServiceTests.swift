import Foundation
import UserNotifications
import XCTest
@testable import SnapSchedule

@MainActor
final class NotificationAuthorizationServiceTests: XCTestCase {
    func testSystemStatusesMapWithoutCollapsingProvisionalOrEphemeralAccess() {
        let cases: [(UNAuthorizationStatus, NotificationAuthorizationAccess, Bool)] = [
            (.notDetermined, .notDetermined, false),
            (.denied, .denied, false),
            (.authorized, .authorized, true),
            (.provisional, .provisional, true),
            (.ephemeral, .ephemeral, true),
        ]

        for (systemStatus, expectedAccess, allowsScheduling) in cases {
            let access = NotificationAuthorizationAccess(systemStatus: systemStatus)

            XCTAssertEqual(access, expectedAccess)
            XCTAssertEqual(access.allowsScheduling, allowsScheduling)
        }
    }

    func testRefreshPublishesChangedSystemStatus() async {
        let systemStatus = NotificationStatusBox(.denied)
        let service = NotificationAuthorizationService(
            statusProvider: { systemStatus.value },
            authorizationRequester: { _ in true }
        )
        systemStatus.value = .provisional

        await service.refresh()

        XCTAssertEqual(service.access, .provisional)
    }

    func testLateOldRefreshCannotOverwriteReallowedStatus() async {
        var firstResponse: CheckedContinuation<UNAuthorizationStatus, Never>?
        var calls = 0
        let service = NotificationAuthorizationService(statusProvider: {
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { firstResponse = $0 }
            }
            return .authorized
        })
        let oldRefresh = Task { await service.refresh() }
        while firstResponse == nil { await Task.yield() }
        await service.refresh()
        XCTAssertEqual(service.access, .authorized)
        firstResponse?.resume(returning: .denied)
        await oldRefresh.value
        XCTAssertEqual(service.access, .authorized, "A late response from the previous activation must not win.")
    }

    func testDisabledRemindersDoNotRequestAuthorization() async {
        var requestCount = 0
        let service = NotificationAuthorizationService(
            statusProvider: { .notDetermined },
            authorizationRequester: { _ in
                requestCount += 1
                return true
            }
        )

        let result = await service.requestAuthorizationIfNeeded(remindersEnabled: false)

        XCTAssertEqual(result, .notNeeded(.notDetermined))
        XCTAssertEqual(requestCount, 0)
    }

    func testNotDeterminedRequestsAlertAndSoundThenPublishesActualStatus() async {
        let systemStatus = NotificationStatusBox(.notDetermined)
        var requestedOptions: UNAuthorizationOptions = []
        let service = NotificationAuthorizationService(
            statusProvider: { systemStatus.value },
            authorizationRequester: { options in
                requestedOptions = options
                systemStatus.value = .denied
                return false
            }
        )

        let result = await service.requestAuthorizationIfNeeded(remindersEnabled: true)

        XCTAssertEqual(result, .requested(.denied))
        XCTAssertEqual(requestedOptions, [.alert, .sound])
        XCTAssertEqual(service.access, .denied)
    }

    func testDeterminedStatusDoesNotRequestAuthorizationAgain() async {
        var requestCount = 0
        let service = NotificationAuthorizationService(
            statusProvider: { .denied },
            authorizationRequester: { _ in
                requestCount += 1
                return false
            }
        )

        let firstResult = await service.requestAuthorizationIfNeeded(remindersEnabled: true)
        let secondResult = await service.requestAuthorizationIfNeeded(remindersEnabled: true)

        XCTAssertEqual(firstResult, .notNeeded(.denied))
        XCTAssertEqual(secondResult, .notNeeded(.denied))
        XCTAssertEqual(requestCount, 0)
    }

    func testRequestFailureIsReportedWithoutThrowing() async {
        let service = NotificationAuthorizationService(
            statusProvider: { .notDetermined },
            authorizationRequester: { _ in throw TestError.requestFailed }
        )

        let result = await service.requestAuthorizationIfNeeded(remindersEnabled: true)

        XCTAssertEqual(result, .failed(.notDetermined))
        XCTAssertEqual(service.access, .notDetermined)
    }
}

@MainActor
private final class NotificationStatusBox {
    var value: UNAuthorizationStatus

    init(_ value: UNAuthorizationStatus) {
        self.value = value
    }
}

private enum TestError: Error {
    case requestFailed
}
