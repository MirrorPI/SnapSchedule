import XCTest
import SwiftData
import SwiftUI
import UIKit
@testable import SnapSchedule

final class ScheduleDatePresentationTests: XCTestCase {
    func testSortsByDateWithAllDayFirstThenTimeAndStableID() {
        let schedules = [
            schedule(id: id(5), date: date(2026, 10, 4), time: nil),
            schedule(id: id(4), date: date(2026, 10, 3), time: time(9, 0)),
            schedule(id: id(2), date: date(2026, 10, 3), time: time(9, 0)),
            schedule(id: id(3), date: date(2026, 10, 3), time: time(8, 30)),
            schedule(id: id(1), date: date(2026, 10, 3), time: nil),
        ]

        let result = ScheduleDatePresentation.sorted(
            schedules,
            now: instant(2026, 10, 1, 12, 0, in: seoul),
            deviceTimeZone: seoul
        )

        XCTAssertEqual(result.map(\.id), [id(1), id(3), id(2), id(4), id(5)])
    }

    func testUpcomingExcludesPassedTimedEventButKeepsAllDayUntilDateEnds() {
        let schedules = [
            schedule(id: id(1), date: date(2026, 10, 3), time: nil),
            schedule(id: id(2), date: date(2026, 10, 3), time: time(9, 59)),
            schedule(id: id(3), date: date(2026, 10, 3), time: time(10, 0)),
            schedule(id: id(4), date: date(2026, 10, 2), time: nil),
        ]

        let result = ScheduleDatePresentation.upcoming(
            schedules,
            now: instant(2026, 10, 3, 10, 0, in: seoul),
            deviceTimeZone: seoul
        )

        XCTAssertEqual(result.map(\.id), [id(1), id(3)])
    }

    func testDayDifferenceUsesCalendarDatesAcrossYearAndDST() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let yearBoundary = schedule(id: id(1), date: date(2027, 1, 1), time: nil)
        let dstBoundary = schedule(id: id(2), date: date(2026, 3, 9), time: nil)

        let yearResult = ScheduleDatePresentation.sorted(
            [yearBoundary],
            now: instant(2026, 12, 31, 23, 30, in: seoul),
            deviceTimeZone: seoul
        )
        let dstResult = ScheduleDatePresentation.sorted(
            [dstBoundary],
            now: instant(2026, 3, 7, 12, 0, in: newYork),
            deviceTimeZone: newYork
        )

        XCTAssertEqual(yearResult.first?.dayDisplay, .future(days: 1))
        XCTAssertEqual(dstResult.first?.dayDisplay, .future(days: 2))
        XCTAssertEqual(yearResult.first?.dayDisplay.dDayText, "D-1")
    }

    func testTimedEventUsesStoredTimeZoneWhileAllDayUsesDeviceDate() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = instant(2026, 1, 1, 16, 30, in: TimeZone(secondsFromGMT: 0)!)
        let timed = schedule(
            id: id(1),
            date: date(2026, 1, 2),
            time: time(10, 0),
            timeZoneIdentifier: tokyo.identifier
        )
        let allDay = schedule(id: id(2), date: date(2026, 1, 2), time: nil)

        let result = ScheduleDatePresentation.sorted(
            [timed, allDay],
            now: now,
            deviceTimeZone: losAngeles
        )

        XCTAssertEqual(result.first { $0.id == timed.id }?.dayDisplay, .today)
        XCTAssertEqual(result.first { $0.id == allDay.id }?.dayDisplay, .future(days: 1))
        XCTAssertEqual(result.first { $0.id == timed.id }?.displayTimeZoneIdentifier, tokyo.identifier)
        XCTAssertNil(result.first { $0.id == allDay.id }?.displayTimeZoneIdentifier)
    }

    func testPastDateHasNoDDayTextAndPreservesCalendarDate() {
        let past = schedule(id: id(1), date: date(2026, 9, 30), time: nil)

        let result = ScheduleDatePresentation.sorted(
            [past],
            now: instant(2026, 10, 1, 0, 0, in: seoul),
            deviceTimeZone: seoul
        )

        XCTAssertEqual(result.first?.dayDisplay, .past(date(2026, 9, 30)))
        XCTAssertNil(result.first?.dayDisplay.dDayText)
    }

    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func schedule(
        id: UUID,
        date: CalendarDate,
        time: ClockTime?,
        timeZoneIdentifier: String? = nil
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: UUID(),
            title: "Schedule \(id.uuidString)",
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            sourceAssetIdentifier: "asset-\(id.uuidString)"
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)
    }

    private func time(_ hour: Int, _ minute: Int) -> ClockTime {
        ClockTime(hour: hour, minute: minute)
    }

    private func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "16000000-0000-0000-0000-%012d", value))!
    }
}

final class HomeAnalysisPresentationTests: XCTestCase {
    func testUnreadablePhotoAccessNeverShowsLimitedAccessWarning() {
        for access in [PhotoLibraryAccess.notDetermined, .denied, .restricted] {
            for state in [ScanRunState.accessUnavailable, .completed] {
                for candidateCount in [0, 2] {
                    XCTAssertNotEqual(
                        HomeAnalysisPresentation(
                            status: ScanStatus(state: state, photoAccess: access),
                            pendingCandidateCount: candidateCount
                        ),
                        .accessLimited,
                        "\(access), \(state), \(candidateCount) saved candidates"
                    )
                }
            }
        }
    }

    func testPhotoAccessTransitionsClearAndRestoreLimitedWarning() {
        for (access, state, expected) in [
            (PhotoLibraryAccess.notDetermined, ScanRunState.accessUnavailable, HomeAnalysisPresentation.accessUnavailable),
            (.limited, .completed, .accessLimited),
            (.denied, .accessUnavailable, .accessUnavailable),
            (.authorized, .completed, .empty),
            (.limited, .completed, .accessLimited),
            (.restricted, .accessUnavailable, .accessUnavailable),
            (.authorized, .completed, .empty)
        ] {
            XCTAssertEqual(
                HomeAnalysisPresentation(
                    status: ScanStatus(state: state, photoAccess: access),
                    pendingCandidateCount: 0
                ),
                expected
            )
        }
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .completed, photoAccess: .authorized),
                pendingCandidateCount: 2
            ),
            .candidatesAvailable
        )
    }

    func testDistinguishesAnalysisRestrictionFailureAndTrueEmptyState() {
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .waiting, photoAccess: .authorized),
                pendingCandidateCount: 0
            ),
            .waiting
        )
        XCTAssertEqual(
            HomeAnalysisPresentation(status: ScanStatus(state: .analyzing), pendingCandidateCount: 0),
            .analyzing
        )
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .completed, photoAccess: .limited),
                pendingCandidateCount: 0
            ),
            .accessLimited
        )
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .completedWithFailures, failedImageCount: 1),
                pendingCandidateCount: 0
            ),
            .failed
        )
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .completed, photoAccess: .authorized),
                pendingCandidateCount: 0
            ),
            .empty
        )
        XCTAssertEqual(
            HomeAnalysisPresentation(
                status: ScanStatus(state: .completed, photoAccess: .authorized),
                pendingCandidateCount: 2
            ),
            .candidatesAvailable
        )
    }
}

final class HomeCalendarPresentationTests: XCTestCase {
    func testDecorationDatesAreUniqueAndPreserveLeapDay() {
        let schedules = [
            schedule(id: 1, date: CalendarDate(year: 2028, month: 2, day: 29)),
            schedule(id: 2, date: CalendarDate(year: 2028, month: 2, day: 29)),
            schedule(id: 3, date: CalendarDate(year: 2028, month: 3, day: 1)),
        ]

        let result = HomeCalendarPresentation.datesWithSchedules(schedules)

        XCTAssertEqual(result, [
            CalendarDate(year: 2028, month: 2, day: 29),
            CalendarDate(year: 2028, month: 3, day: 1),
        ])
    }

    func testSelectedDateIncludesOnlySchedulesStoredOnThatCalendarDate() {
        let selectedDate = CalendarDate(year: 2026, month: 10, day: 3)
        let schedules = [
            schedule(id: 3, date: selectedDate, time: ClockTime(hour: 9, minute: 30)),
            schedule(id: 1, date: selectedDate),
            schedule(id: 2, date: CalendarDate(year: 2026, month: 10, day: 4)),
        ]

        let result = HomeCalendarPresentation.schedules(
            on: selectedDate,
            from: schedules,
            now: instant(2026, 10, 1, 12, 0, timeZone: seoul),
            deviceTimeZone: seoul
        )

        XCTAssertEqual(result.map(\.id), [id(1), id(3)])
    }

    // An older registration with a later event time must still lead the selected-day originals.
    func testSelectedDateUsesRegistrationOrderWithoutChangingUpcomingOrder() {
        let day = CalendarDate(year: 2026, month: 10, day: 3)
        let first = schedule(id: 3, date: day, time: ClockTime(hour: 20, minute: 0))
        let second = schedule(id: 1, date: day)
        first.createdAt = Date(timeIntervalSince1970: 10)
        second.createdAt = Date(timeIntervalSince1970: 20)
        let now = instant(2026, 10, 1, 12, 0, timeZone: seoul)
        XCTAssertEqual(HomeCalendarPresentation.schedules(on: day, from: [second, first], now: now,
                                                        deviceTimeZone: seoul).map(\.id), [id(3), id(1)])
        XCTAssertEqual(ScheduleDatePresentation.upcoming([second, first], now: now,
                                                       deviceTimeZone: seoul).map(\.id), [id(1), id(3)])
    }

    func testStoredDateDoesNotShiftForScheduleInAnotherTimeZone() {
        let selectedDate = CalendarDate(year: 2026, month: 1, day: 2)
        let tokyoSchedule = schedule(
            id: 1,
            date: selectedDate,
            time: ClockTime(hour: 0, minute: 30),
            timeZoneIdentifier: "Asia/Tokyo"
        )

        let result = HomeCalendarPresentation.schedules(
            on: selectedDate,
            from: [tokyoSchedule],
            now: instant(2026, 1, 1, 0, 0, timeZone: losAngeles),
            deviceTimeZone: losAngeles
        )

        XCTAssertEqual(result.map(\.id), [id(1)])
        XCTAssertEqual(result.first?.displayTimeZoneIdentifier, "Asia/Tokyo")
    }

    func testDecorationReloadDatesIncludeRemovedAndAddedDatesOnly() {
        let januaryFirst = CalendarDate(year: 2027, month: 1, day: 1)
        let januarySecond = CalendarDate(year: 2027, month: 1, day: 2)
        let januaryThird = CalendarDate(year: 2027, month: 1, day: 3)

        let result = HomeCalendarPresentation.datesNeedingDecorationReload(
            previous: [januaryFirst, januarySecond],
            current: [januarySecond, januaryThird]
        )

        XCTAssertEqual(result, [januaryFirst, januaryThird])
    }

    func testSameSourceKeepsEachRegistrationAndTiesAreStable() {
        let day = CalendarDate(year: 2026, month: 10, day: 3)
        let first = Schedule(id: id(2), sourceCandidateID: UUID(), title: "Booking", date: day,
                             sourceAssetIdentifier: "shared", createdAt: Date(timeIntervalSince1970: 10))
        let second = Schedule(id: id(1), sourceCandidateID: UUID(), title: "Concert", date: day,
                              sourceAssetIdentifier: "shared", createdAt: Date(timeIntervalSince1970: 10))
        let third = schedule(id: 3, date: day)
        third.createdAt = Date(timeIntervalSince1970: 20)
        let originals = HomeCalendarPresentation.registeredSchedules(on: day, from: [third, first, second])
        XCTAssertEqual(originals.map(\.id), [id(1), id(2), id(3)])
        XCTAssertEqual(originals.map(\.sourceAssetIdentifier), ["shared", "shared", "asset-3"])
        let decoration = HomeCalendarPresentation.originalsByDate([third, first, second])
        XCTAssertEqual(decoration.first?.scheduleID, id(1))
        XCTAssertEqual(decoration.first?.sourceAssetIdentifier, "shared")
        XCTAssertEqual(decoration.first?.additionalCount, 2)
        XCTAssertTrue(HomeCalendarPresentation.registeredSchedules(on: CalendarDate(year: 2026, month: 10, day: 4), from: originals).isEmpty)
    }

    func testReloadIncludesSameDateCountRepresentativeTitleAndDateChanges() {
        let a = CalendarDate(year: 2026, month: 10, day: 3)
        let b = CalendarDate(year: 2026, month: 11, day: 3)
        let first = schedule(id: 1, date: a), second = schedule(id: 2, date: a)
        let initial = HomeCalendarPresentation.originalsByDate([first])
        let added = HomeCalendarPresentation.originalsByDate([first, second])
        XCTAssertEqual(HomeCalendarPresentation.datesNeedingDecorationReload(previous: initial, current: added), [a])
        let removedFirst = HomeCalendarPresentation.originalsByDate([second])
        XCTAssertEqual(HomeCalendarPresentation.datesNeedingDecorationReload(previous: added, current: removedFirst), [a])
        XCTAssertEqual(removedFirst.first?.scheduleID, id(2))
        second.title = "Updated booking"
        let renamed = HomeCalendarPresentation.originalsByDate([second])
        XCTAssertEqual(HomeCalendarPresentation.datesNeedingDecorationReload(previous: removedFirst, current: renamed), [a])
        second.date = b
        let moved = HomeCalendarPresentation.originalsByDate([second])
        XCTAssertEqual(HomeCalendarPresentation.datesNeedingDecorationReload(previous: renamed, current: moved), [a, b])
        XCTAssertEqual(HomeCalendarPresentation.datesNeedingDecorationReload(previous: moved, current: [] as [CalendarDayOriginal]), [b])
        XCTAssertTrue(HomeCalendarPresentation.datesNeedingDecorationReload(previous: moved, current: moved).isEmpty)
    }

    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func schedule(
        id value: Int,
        date: CalendarDate,
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil
    ) -> Schedule {
        Schedule(
            id: id(value),
            sourceCandidateID: UUID(),
            title: "Schedule \(value)",
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            sourceAssetIdentifier: "asset-\(value)",
            createdAt: Date(timeIntervalSince1970: Double(value))
        )
    }

    private func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "17000000-0000-0000-0000-%012d", value))!
    }
}

final class LocalizationTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: AppSettings.self) }

    func testAppPackagesThreeLanguagesAndEnglishFallback() throws {
        for language in ["en", "ko", "ja"] {
            XCTAssertNotNil(appBundle.path(forResource: language, ofType: "lproj"), language)
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "ko", "ja"], forPreferences: ["fr"]), ["en"])
    }

    func testTranslatedPermissionAndPluralResourcesResolveAtRuntime() throws {
        for (language, home, single, many) in [
            ("en", "Home", "Register 1 schedule", "Register 3 schedules"),
            ("ko", "홈", "미등록 일정 1개 등록", "미등록 일정 3개 등록"),
            ("ja", "ホーム", "未登録の予定を1件登録", "未登録の予定を3件登録")
        ] {
            let path = try XCTUnwrap(appBundle.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Home", value: nil, table: nil), home)
            let format = bundle.localizedString(forKey: "Register %lld candidates", value: nil, table: nil)
            XCTAssertEqual(String(format: format, locale: Locale(identifier: language), arguments: [Int64(1)]), single)
            XCTAssertEqual(String(format: format, locale: Locale(identifier: language), arguments: [Int64(3)]), many)
            let purpose = bundle.localizedString(forKey: "NSPhotoLibraryUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertFalse(purpose.contains("NSPhotoLibraryUsageDescription"))
            XCTAssertFalse(purpose.isEmpty)
        }
    }
}

final class CandidateLocalizationTests: XCTestCase {
    func testCandidateFormatsSavedDateAndTimeInEachLocale() {
        let candidate = ScheduleCandidate(
            sourceAssetIdentifier: "asset", sourceCandidateKey: "key", title: "User title",
            date: CalendarDate(year: 2026, month: 10, day: 2),
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul"
        )
        let english = CandidateText.dateAndTime(candidate, locale: Locale(identifier: "en_US"))
        let korean = CandidateText.dateAndTime(candidate, locale: Locale(identifier: "ko_KR"))
        let japanese = CandidateText.dateAndTime(candidate, locale: Locale(identifier: "ja_JP"))
        XCTAssertTrue(english.contains("Oct"), english)
        XCTAssertTrue(english.contains("PM"), english)
        XCTAssertTrue(korean.contains("10월"), korean)
        XCTAssertTrue(korean.contains("오후"), korean)
        XCTAssertTrue(japanese.contains("10月"), japanese)
        XCTAssertEqual(candidate.title, "User title")
        XCTAssertEqual(candidate.time, ClockTime(hour: 14, minute: 0))
    }

    func testCandidateDisplayPreservesStoredClockDuringDSTGap() {
        let candidate = ScheduleCandidate(
            sourceAssetIdentifier: "asset", sourceCandidateKey: "dst", title: "User title",
            date: CalendarDate(year: 2026, month: 3, day: 8),
            time: ClockTime(hour: 2, minute: 30), timeZoneIdentifier: "America/Los_Angeles"
        )
        let text = CandidateText.dateAndTime(candidate, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.contains("2:30"), text)
        XCTAssertFalse(text.contains("3:30"), text)
        XCTAssertEqual(candidate.time, ClockTime(hour: 2, minute: 30))
    }

    func testParserFallbackIsLocalizedForDisplayWithoutChangingStoredTitle() {
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "asset", sourceCandidateKey: "key", title: "일정 확인 필요", reviewReason: .missingTitle)
        XCTAssertEqual(CandidateText.displayTitle(candidate), String(localized: "Schedule needs review"))
        XCTAssertEqual(candidate.title, "일정 확인 필요")
        XCTAssertFalse(candidate.isRegistrationEligible)
    }
}

@MainActor
final class LocalizationScreenTests: XCTestCase {
    func testCoreScreensKeepLocalizedActionsAccessibleWithLargeType() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext
        let candidate = ScheduleCandidate(
            sourceAssetIdentifier: "localization-fixture", sourceCandidateKey: "candidate",
            title: "Localization fixture", date: CalendarDate(year: 2026, month: 10, day: 5),
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul",
            reviewReason: .timeZoneInferred
        )
        let schedule = Schedule(
            sourceCandidateID: UUID(), title: "Localization fixture",
            date: CalendarDate(year: 2026, month: 10, day: 5),
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: "localization-fixture", calendarExportStatus: .failed,
            calendarExportFailureMessage: "Calendar access is denied. The schedule remains saved in SnapSchedule."
        )
        context.insert(candidate)
        context.insert(schedule)
        try context.save()
        let notificationAuthorization = NotificationAuthorizationService(
            statusProvider: { .denied }, authorizationRequester: { _ in false }
        )
        let photoAuthorization = PhotoAuthorizationService(
            statusProvider: { .notDetermined }, authorizationRequester: { .notDetermined }
        )
        let scanCoordinator = ScanCoordinator(
            context: context, settings: AppSettings(), discover: { .unavailable($0) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] }
        )
        let screens: [(String, AnyView, String)] = [
            ("Onboarding", AnyView(PhotoAccessView(authorization: photoAuthorization).padding()), String(localized: "Continue")),
            ("Home", AnyView(HomeView(scanCoordinator: scanCoordinator, notificationNavigation: NotificationNavigationStore())), String(localized: "Settings")),
            ("Analysis", AnyView(ScanStatusView(status: ScanStatus(state: .completedWithFailures, photoAccess: .limited, targetImageCount: 10, completedImageCount: 8, failedImageCount: 2, pendingCandidateCount: 3), candidateSummary: CandidateReviewSummary(candidates: [candidate])).padding()), String(localized: "Analysis completed with failures")),
            ("Candidates", AnyView(NavigationStack { CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in }) }), String(localized: "Original screenshot")),
            ("CandidateDetail", AnyView(NavigationStack { CandidateDetailView(candidate: candidate) }), String(localized: "Register schedule")),
            ("ScheduleDetail", AnyView(NavigationStack { ScheduleDetailView(schedule: schedule, notificationAuthorization: notificationAuthorization, notificationScheduler: NotificationScheduler()) }), String(localized: "Edit")),
            ("ScheduleEdit", AnyView(NavigationStack { ScheduleEditView(schedule: schedule, notificationAuthorization: notificationAuthorization) }), String(localized: "Save")),
            ("Settings", AnyView(SettingsView(notificationAuthorization: notificationAuthorization)), String(localized: "Done"))
        ]
        for (name, screen, expectedAction) in screens {
            let controller = UIHostingController(rootView: screen.modelContainer(container).environment(\.dynamicTypeSize, .accessibility3))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            let labels = accessibilityLabels(in: controller.view)
            XCTAssertTrue(labels.contains { $0.contains(expectedAction) }, "\(name): \(labels)")
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(Bundle.main.preferredLocalizations.first ?? "unknown")-\(name)-large-type"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
        scanCoordinator.cancel()
    }

    private func accessibilityLabels(in view: UIView) -> [String] {
        var labels: [String] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, let label = object.accessibilityLabel { labels.append(label) }
            object.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(visit)
            if let view = object as? UIView { view.subviews.forEach(visit) }
        }
        visit(view)
        return labels
    }
}

// Public UIKit decoration sizing probe: the entire image and count must fit in its clipped slot.
@MainActor
final class CalendarDecorationFeasibilityTests: XCTestCase {
    func testNativeCustomDecorationFitsWholeThumbnailAndCount() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let calendar = UICalendarView(frame: CGRect(x: 16, y: 70, width: window.bounds.width - 32, height: 350))
        calendar.calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let delegate = DecorationProbeDelegate()
        calendar.delegate = delegate
        calendar.setVisibleDateComponents(DateComponents(year: 2026, month: 10), animated: false)
        controller.view.addSubview(calendar)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        calendar.layoutIfNeeded()
        let view = try XCTUnwrap(delegate.decoration)
        print("NATIVE_DECORATION_BOUNDS", view.bounds, "PARENT", view.superview?.bounds as Any)
        XCTAssertGreaterThanOrEqual(view.bounds.width, 32)
        XCTAssertGreaterThanOrEqual(view.bounds.height, 14)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "native-calendar-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class DecorationProbeDelegate: NSObject, UICalendarViewDelegate {
    var decoration: UIView?
    func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
        guard dateComponents.day == 5 else { return nil }
        return .customView {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 34, height: 16))
            let image = UIImageView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
            image.contentMode = .scaleAspectFit
            image.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { ctx in
                UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
                UIColor.systemYellow.setFill(); ctx.fill(CGRect(x: 0, y: 270, width: 200, height: 30))
            }
            let label = UILabel(frame: CGRect(x: 18, y: 0, width: 16, height: 16))
            label.text = "+2"; label.font = .systemFont(ofSize: 9)
            view.addSubview(image); view.addSubview(label)
            self.decoration = view
            return view
        }
    }
}

@MainActor
final class HomeRegisteredOriginalTests: XCTestCase {
    func testHomeSelectedDayShowsOriginalWithoutCandidateIgnoreAction() throws {
        let container = try makeContainer()
        let schedule = Schedule(sourceCandidateID: UUID(), title: "Registered original fixture",
                                date: CalendarDate.gregorianDate(from: .now), sourceAssetIdentifier: "home-original")
        container.mainContext.insert(schedule)
        try container.mainContext.save()
        let scan = ScanCoordinator(context: container.mainContext, settings: AppSettings(),
            discover: { .unavailable($0) }, loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible },
            recognizeText: { _ in [] })
        let data = fixtureImage().pngData()!
        let controller = UIHostingController(rootView: HomeView(scanCoordinator: scan,
            notificationNavigation: NotificationNavigationStore(),
            notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in false }))
            .modelContainer(container).environment(\.scenePhase, .active).environment(\.screenshotThumbnailFactory, { identifier in
                ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in
                    ScreenshotImageInput(data: data, orientation: .up)
                }
            }))
        let (window, previous) = try show(controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); scan.cancel() }
        settle(0.7)
        var seen = Set(labels(controller.view))
        if let scroll = scrollView(controller.view) {
            var y: CGFloat = 0
            while y <= scroll.contentSize.height {
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false); settle(0.15)
                seen.formUnion(labels(controller.view)); y += max(160, scroll.bounds.height * 0.55)
            }
        }
        XCTAssertTrue(seen.contains { $0.contains(String(localized: "Original screenshot")) }, "Missing registered original: \(seen)")
        XCTAssertFalse(seen.contains { $0.contains(String(localized: "Ignore Candidate")) })
    }

    func testCalendarMonthSelectionAndChangedDecorationRenderWholeImages() throws {
        let october = CalendarDate(year: 2026, month: 10, day: 5)
        let november = CalendarDate(year: 2026, month: 11, day: 6)
        let fixtures = [makeSchedule(1, date: october), makeSchedule(2, date: october), makeSchedule(3, date: november)]
        var selected = october
        let data = fixtureImage().pngData()!
        let factory: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
            ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in ScreenshotImageInput(data: data, orientation: .up) }
        }
        let binding = Binding(get: { selected }, set: { selected = $0 })
        func root(_ schedules: [Schedule]) -> some View {
            HomeCalendarView(originals: HomeCalendarPresentation.originalsByDate(schedules), selectedDate: binding,
                timeZone: TimeZone(identifier: "Asia/Seoul")!)
                .environment(\.screenshotCalendarThumbnailFactory, factory)
                .environment(\.scenePhase, .active)
                .padding(.horizontal, 16)
        }
        let controller = UIHostingController(rootView: root(fixtures))
        let (window, previous) = try show(controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        settle(0.5)
        let calendar = try XCTUnwrap(subviews(controller.view).compactMap { $0 as? UICalendarView }.first)
        calendar.setVisibleDateComponents(DateComponents(year: 2026, month: 10), animated: false); settle(0.5)
        verifyDecorations(calendar)
        attach(controller.view, name: "calendar-october-whole-original-plus-one")
        let coordinator = try XCTUnwrap(calendar.delegate as? HomeCalendarView.Coordinator)
        let selection = try XCTUnwrap(calendar.selectionBehavior as? UICalendarSelectionSingleDate)
        coordinator.dateSelection(selection, didSelectDate: DateComponents(year: 2026, month: 10, day: 5))
        XCTAssertEqual(selected, october)
        calendar.setVisibleDateComponents(DateComponents(year: 2026, month: 11), animated: false); settle(0.5)
        XCTAssertEqual(selected, october, "A month change must not silently change the selected day")
        verifyDecorations(calendar)
        attach(controller.view, name: "calendar-november-whole-original")
        coordinator.dateSelection(selection, didSelectDate: DateComponents(year: 2026, month: 11, day: 6))
        XCTAssertEqual(selected, november)
        controller.rootView = root([fixtures[1], fixtures[2]]); settle(0.5)
        XCTAssertEqual(coordinator.originals.first?.scheduleID, fixtures[1].id)
        XCTAssertEqual(coordinator.originals.first?.additionalCount, 0)
        controller.rootView = root([]); settle(0.5)
        XCTAssertTrue(coordinator.originals.isEmpty)
        XCTAssertFalse(subviews(calendar).contains { $0 is CalendarOriginalDecorationView && $0.window != nil })
    }

    func testActualHomeOriginalsRenderZeroMultipleSharedPhotoUnavailableAndMutations() throws {
        for large in [false, true] {
            let container = try makeContainer()
            let context = container.mainContext
            let day = CalendarDate.gregorianDate(from: .now)
            let first = makeSchedule(1, date: day), second = makeSchedule(2, date: day), unavailable = makeSchedule(3, date: day)
            let shared = Schedule(id: UUID(), sourceCandidateID: UUID(), title: "Shared photo · second registration", date: day,
                sourceAssetIdentifier: first.sourceAssetIdentifier, createdAt: Date(timeIntervalSince1970: 4))
            [first, second, unavailable, shared].forEach(context.insert)
            try context.save()
            let scan = ScanCoordinator(context: context, settings: AppSettings(), discover: { .unavailable($0) },
                loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
            let unavailableIdentifier = unavailable.sourceAssetIdentifier
            let factory: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
                let data = self.fixtureImage(landscape: identifier == second.sourceAssetIdentifier).pngData()!
                return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in
                    if identifier == unavailableIdentifier { throw ScreenshotImageLoadError.inaccessible }
                    return ScreenshotImageInput(data: data, orientation: .up)
                }
            }
            let controller = UIHostingController(rootView: HomeView(scanCoordinator: scan, notificationNavigation: NotificationNavigationStore(),
                notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in false }))
                .modelContainer(container).environment(\.scenePhase, .active).environment(\.screenshotThumbnailFactory, factory)
                .environment(\.screenshotCalendarThumbnailFactory, factory)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                .environment(\.colorScheme, large ? .dark : .light))
            let (window, previous) = try show(controller)
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); scan.cancel() }
            settle(0.7)
            attach(controller.view, name: "home-\(large ? "large-dark" : "light")-calendar-top")
            if let scroll = scrollView(controller.view) {
                var y: CGFloat = 0
                while y <= scroll.contentSize.height {
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false); settle(0.18)
                    if let original = objects(controller.view).first(where: { self.identifier($0) == "schedule-original-\(first.id)" }) {
                        let target = scroll.contentOffset.y + original.accessibilityFrame.minY - 130
                        scroll.setContentOffset(CGPoint(x: 0, y: max(0, target)), animated: false); settle(0.2)
                        attach(controller.view, name: "home-\(large ? "large-dark" : "light")-whole-selected-original")
                        break
                    }
                    y += max(160, scroll.bounds.height * 0.5)
                }
            }
            let seen = captureScroll(controller.view, name: "home-\(large ? "large-dark" : "light")")
            for schedule in [first, second, shared] {
                XCTAssertTrue(seen.contains { $0.contains(String(localized: "Original screenshot")) && $0.contains(schedule.title) })
            }
            XCTAssertTrue(seen.contains { $0.contains(String(localized: "Screenshot Unavailable")) })
            XCTAssertTrue(seen.contains { $0.contains(String(localized: "Upcoming schedules")) })
            for removedStatus in ["Screenshot analysis", "Photo access", "Notifications"] {
                XCTAssertFalse(seen.contains(String(localized: String.LocalizationValue(removedStatus))))
            }
            XCTAssertFalse(objects(controller.view).contains { self.identifier($0)?.hasPrefix("candidate-ignore-") == true })
            var draft = ScheduleEditDraft(schedule: first)
            draft.title = "Edited original registration"
            draft.date = CalendarDate(year: day.year + 1, month: 1, day: 1)
            let service = ScheduleMutationService(context: context, widgetSnapshotRefresh: {})
            _ = try service.update(scheduleID: first.id, draft: draft)
            settle(0.4)
            let afterMove = captureScroll(controller.view, name: "home-after-date-edit", attachImages: false)
            XCTAssertFalse(afterMove.contains { $0.contains(String(localized: "Original screenshot")) && $0.contains(draft.title) })
            XCTAssertEqual(HomeCalendarPresentation.originalsByDate(try context.fetch(FetchDescriptor<Schedule>())).first?.scheduleID, second.id)
            for schedule in [second, unavailable, shared] { _ = try service.delete(scheduleID: schedule.id) }
            settle(0.4)
            let empty = captureScroll(controller.view, name: "home-selected-date-empty", attachImages: !large)
            XCTAssertTrue(empty.contains { $0.contains(String(localized: "No schedules on this date")) })
        }
    }

    func testSharedOriginalImageActivatesItsOwnScheduleDetail() throws {
        let container = try makeContainer()
        let first = makeSchedule(1, date: CalendarDate.gregorianDate(from: .now))
        let second = Schedule(sourceCandidateID: UUID(), title: "Second schedule from shared original", date: first.date,
            sourceAssetIdentifier: first.sourceAssetIdentifier, createdAt: Date(timeIntervalSince1970: 2))
        [first, second].forEach(container.mainContext.insert); try container.mainContext.save()
        let data = fixtureImage().pngData()!
        let scan = ScanCoordinator(context: container.mainContext, settings: AppSettings(), discover: { .unavailable($0) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
        let controller = UIHostingController(rootView: HomeView(scanCoordinator: scan, notificationNavigation: NotificationNavigationStore(),
            notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in false }))
            .modelContainer(container).environment(\.scenePhase, .active)
            .environment(\.screenshotThumbnailFactory, { identifier in
                ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in ScreenshotImageInput(data: data, orientation: .up) }
            }))
        let (window, previous) = try show(controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); scan.cancel() }
        settle(0.6)
        let scroll = try XCTUnwrap(scrollView(controller.view))
        var original: NSObject?
        var y: CGFloat = 0
        while original == nil && y <= scroll.contentSize.height {
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false); settle(0.2)
            original = objects(controller.view).first { self.identifier($0) == "schedule-original-\(second.id)" }
            y += max(160, scroll.bounds.height * 0.5)
        }
        XCTAssertTrue(activate(try XCTUnwrap(original)))
        settle(0.7)
        let navigation = try XCTUnwrap(navigationController(controller))
        let detail = try XCTUnwrap(navigation.visibleViewController?.view)
        XCTAssertTrue(labels(controller.view).contains(String(localized: "Edit")))
        XCTAssertTrue(labels(detail).contains { $0.contains(second.title) })
        XCTAssertFalse(labels(detail).contains { $0.contains(first.title) })
        attach(controller.view, name: "shared-original-to-its-own-schedule-detail")
    }

    func testCalendarDecorationCancelsAndRechecksOnActivation() throws {
        let attempts = CalendarLoadAttempts()
        let data = fixtureImage().pngData()!
        let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: "activation-fixture") { _, _ in
            if attempts.next() > 1 { throw ScreenshotImageLoadError.inaccessible }
            return ScreenshotImageInput(data: data, orientation: .up)
        }
        let schedule = makeSchedule(1, date: CalendarDate.gregorianDate(from: .now))
        let original = try XCTUnwrap(HomeCalendarPresentation.originalsByDate([schedule]).first)
        let decoration = CalendarOriginalDecorationView(original: original, model: model)
        let controller = UIViewController(); controller.view.addSubview(decoration)
        let (window, previous) = try show(controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        settle(0.3); XCTAssertEqual(model.status, .ready)
        decoration.setActive(false); XCTAssertEqual(model.status, .idle); XCTAssertNil(model.image)
        decoration.setActive(true); settle(0.3)
        XCTAssertEqual(model.status, .inaccessible)
        XCTAssertTrue(decoration.accessibilityLabel?.contains(String(localized: "Screenshot Unavailable")) == true)
        window.isHidden = true; XCTAssertNil(model.image)
    }

    // iOS 26.5 SwiftData query observers can outlive a detached test hosting window.
    // Retain their in-memory stores for this process; production has one persistent App container.
    private static var testContainers: [ModelContainer] = []
    private func makeContainer() throws -> ModelContainer {
        let container = try SnapScheduleModelContainer.makeInMemory()
        Self.testContainers.append(container)
        return container
    }
    private func navigationController(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController($0) }.first
    }
    private func makeSchedule(_ index: Int, date: CalendarDate) -> Schedule {
        Schedule(id: UUID(), sourceCandidateID: UUID(),
            title: "Registration \(index) · \(index == 1 ? "Concert" : "Booking")", date: date,
            time: ClockTime(hour: index == 1 ? 20 : 9, minute: 0), timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: "home-original-\(index)", createdAt: Date(timeIntervalSince1970: Double(index)))
    }
    private func verifyDecorations(_ calendar: UICalendarView) {
        let decorations = subviews(calendar).compactMap { $0 as? CalendarOriginalDecorationView }.filter { $0.window != nil }
        XCTAssertFalse(decorations.isEmpty)
        for decoration in decorations {
            for child in decoration.subviews where !child.isHidden {
                XCTAssertTrue(decoration.bounds.insetBy(dx: -0.01, dy: -0.01).contains(child.frame), "Decoration clips content")
            }
            let image = decoration.subviews.compactMap { $0 as? UIImageView }.first
            XCTAssertEqual(image?.contentMode, .scaleAspectFit)
            if let size = image?.image?.size {
                XCTAssertEqual(size.width / size.height, 2.0 / 3.0, accuracy: 0.001)
            } else { XCTFail("Original image did not load") }
        }
    }
    private func captureScroll(_ view: UIView, name: String, attachImages: Bool = true) -> Set<String> {
        var seen = Set(labels(view))
        if let scroll = scrollView(view) {
            var y: CGFloat = 0, index = 0
            while y <= scroll.contentSize.height {
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false); settle(0.18)
                seen.formUnion(labels(view))
                if attachImages { attach(view, name: "\(name)-scroll-\(index)") }
                y += max(160, scroll.bounds.height * 0.55); index += 1
            }
        }
        return seen
    }
    private func subviews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { subviews($0) } }
    private func attach(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "\(name)-\(Bundle.main.preferredLocalizations.first ?? "unknown")"
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func identifier(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
    }
    private func activate(_ object: NSObject) -> Bool {
        if object.accessibilityActivate() { return true }
        let selector = NSSelectorFromString("accessibilityActivate")
        return object.responds(to: selector) && object.accessibilityActivate()
    }

    private func fixtureImage(landscape: Bool = false) -> UIImage {
        let size = landscape ? CGSize(width: 480, height: 320) : CGSize(width: 320, height: 480)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 23), .foregroundColor: UIColor.darkGray]
            ("SYNTHETIC ORIGINAL" as NSString).draw(at: CGPoint(x: 12, y: 16), withAttributes: attributes)
            ("Concert\n2026.10.05" as NSString).draw(at: CGPoint(x: 20, y: 200), withAttributes: attributes)
            ("END OF ORIGINAL" as NSString).draw(at: CGPoint(x: 20, y: size.height - 40), withAttributes: attributes)
        }
    }
    private func show(_ controller: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds; window.rootViewController = controller; window.makeKeyAndVisible()
        return (window, previous)
    }
    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    private func scrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView($0) }.first
    }
    private func labels(_ view: UIView) -> [String] {
        objects(view).compactMap { $0.isAccessibilityElement ? $0.accessibilityLabel : nil }
    }
    private func objects(_ view: UIView) -> [NSObject] {
        var result: [NSObject] = []; var visited = Set<ObjectIdentifier>()
        func visit(_ item: NSObject) {
            guard visited.insert(ObjectIdentifier(item)).inserted else { return }; result.append(item)
            item.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(visit)
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for i in 0..<count { if let child = item.accessibilityElement(at: i) as? NSObject { visit(child) } }
            }
            (item as? UIView)?.subviews.forEach(visit)
        }
        visit(view); return result
    }
}

private final class CalendarLoadAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1; return count
    }
}
