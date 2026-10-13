import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class ScheduleRegistrationServiceTests: XCTestCase {
    func testRealReadOnlyStoreRejectsEntireBatchAndPreservesSavedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "readonly-batch.store")
        let sourceID = id(426)
        try autoreleasepool {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: url))
            let source = candidate(id: sourceID, key: "readonly-batch", title: "Keep input")
            source.dateEntries = [CandidateDateEntry(date: source.date), CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20))]
            context.insert(source); try context.save()
        }
        let schema = Schema([ScreenshotScan.self, ScheduleCandidate.self, Schedule.self])
        let configuration = ModelConfiguration("SnapSchedule", schema: schema, url: url,
            allowsSave: false, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container); context.autosaveEnabled = false
        XCTAssertThrowsError(try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}).register(candidateIDs: [sourceID])) {
            XCTAssertEqual($0 as? ScheduleRegistrationError, .saveFailed)
        }
        let fresh = ModelContext(container)
        let source = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(source.reviewStatus, .pending); XCTAssertTrue(source.registeredScheduleIDs.isEmpty)
        XCTAssertEqual(source.title, "Keep input"); XCTAssertEqual(source.dateEntries.count, 2)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 0)
    }
    func testDeletedRegisteredBatchCannotBeRegisteredOrDismissedFromStaleContext() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let stale = ModelContext(container); stale.autosaveEnabled = false
        let source = candidate(id: id(425), key: "deleted-batch", title: "Registered source")
        source.dateEntries = [CandidateDateEntry(date: source.date), CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20))]
        stale.insert(source); try stale.save()
        let active = ModelContext(container); active.autosaveEnabled = false
        let result = try ScheduleRegistrationService(context: active, widgetSnapshotRefresh: {}).register(candidateIDs: [source.id])
        for schedule in try active.fetch(FetchDescriptor<Schedule>()) { active.delete(schedule) }
        try active.save()
        XCTAssertThrowsError(try ScheduleRegistrationService(context: stale, widgetSnapshotRefresh: {}).register(candidateIDs: [source.id]))
        XCTAssertThrowsError(try CandidateDismissalService(context: stale).dismiss(candidateIDs: [source.id]))
        let fresh = ModelContext(container)
        let kept = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(kept.reviewStatus, .registered)
        XCTAssertEqual(kept.registeredScheduleIDs, result.scheduleIDs)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 0)
    }
    func testOtherContextStateChangeBlocksStaleBatchWithoutOverwritingInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try SnapScheduleModelContainer.make(url: directory.appending(path: "state.store"))
        let context = ModelContext(container); context.autosaveEnabled = false
        let source = candidate(id: id(424), key: "stale-batch", title: "Saved input")
        source.dateEntries = [CandidateDateEntry(date: source.date), CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20))]
        context.insert(source); try context.save()
        let other = ModelContext(container); other.autosaveEnabled = false
        let changed = try XCTUnwrap(try other.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        changed.reviewStatus = .dismissed; try other.save()
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try service.register(candidateIDs: [source.id]))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Schedule>()), 0)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first?.reviewStatus, .dismissed)
        XCTAssertEqual(source.dateEntries.count, 2)
        XCTAssertEqual(source.title, "Saved input")
    }
    func testOneCandidateRegistersAllIndependentDatesAndCannotRegisterAgain() throws {
        let context = try makeContext()
        let source = candidate(id: id(421), key: "batch", title: "Shared title",
            notifyDayBefore: true, calendarExportRequested: true)
        source.dateEntries = [
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 18), time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20), time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "America/Los_Angeles"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 21), timeZoneIdentifier: "Asia/Tokyo")
        ]
        context.insert(source); try context.save()
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
        let result = try service.register(candidateIDs: [source.id])
        XCTAssertEqual(result.scheduleIDs.count, 3)
        let schedules = try context.fetch(FetchDescriptor<Schedule>()).sorted { $0.date.day < $1.date.day }
        XCTAssertEqual(schedules.count, 3)
        XCTAssertEqual(schedules.map(\.title), ["Shared title", "Shared title", "Shared title"])
        XCTAssertEqual(schedules.map(\.sourceCandidateID), [source.id, source.id, source.id])
        XCTAssertEqual(schedules.map(\.time), [ClockTime(hour: 14, minute: 0), ClockTime(hour: 9, minute: 0), nil])
        XCTAssertEqual(schedules.map(\.timeZoneIdentifier), ["Asia/Seoul", "America/Los_Angeles", "Asia/Tokyo"])
        XCTAssertTrue(schedules.allSatisfy { $0.sourceAssetIdentifier == "asset-batch" && $0.notifyDayBefore && $0.calendarExportStatus == .pending })
        XCTAssertEqual(source.reviewStatus, .registered)
        XCTAssertEqual(Set(source.registeredScheduleIDs), Set(result.scheduleIDs))
        XCTAssertThrowsError(try service.register(candidateIDs: [source.id]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 3)
    }

    func testBatchSaveFailureLeavesAllDatesPendingAndRetryCreatesExactlyTheBatch() throws {
        let context = try makeContext()
        let source = candidate(id: id(422), key: "retry-batch", title: "Retry")
        source.dateEntries = [CandidateDateEntry(date: source.date), CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20))]
        context.insert(source); try context.save()
        let input = source.dateEntries
        var fail = true
        let service = ScheduleRegistrationService(context: context, save: { context in
            if fail { throw TestError.saveFailed }; try context.save()
        }, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try service.register(candidateIDs: [source.id]))
        XCTAssertEqual(source.dateEntries, input)
        XCTAssertEqual(source.reviewStatus, .pending)
        XCTAssertTrue(source.registeredScheduleIDs.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        fail = false
        XCTAssertEqual(try service.register(candidateIDs: [source.id]).scheduleIDs.count, 2)
    }

    func testInvalidOrDuplicateDateBlocksEntireBatchButDifferentTimesAreAllowed() throws {
        let context = try makeContext()
        let source = candidate(id: id(423), key: "validation-batch", title: "Review")
        let first = CandidateDateEntry(date: source.date, time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")
        context.insert(source); try context.save()
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
        for invalid in [CandidateDateEntry(date: CalendarDate(year: 2026, month: 2, day: 30)),
                        CandidateDateEntry(date: source.date, time: ClockTime(hour: 25, minute: 0), timeZoneIdentifier: "UTC"),
                        CandidateDateEntry(date: source.date, time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "Invalid/Zone"), first] {
            source.dateEntries = [first, invalid]; try context.save()
            XCTAssertThrowsError(try service.register(candidateIDs: [source.id]))
            XCTAssertEqual(source.reviewStatus, .pending)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        }
        source.dateEntries = [first, CandidateDateEntry(date: first.date, time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "Asia/Seoul")]
        try context.save()
        XCTAssertEqual(try service.register(candidateIDs: [source.id]).scheduleIDs.count, 2)
    }
    private enum TestError: Error {
        case saveFailed
    }

    func testEmptySelectionDoesNotRegisterAnything() throws {
        let context = try makeContext()
        context.insert(candidate(id: id(1), key: "one", title: "One"))
        try context.save()

        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})

        XCTAssertThrowsError(try service.register(candidateIDs: [])) {
            XCTAssertEqual($0 as? ScheduleRegistrationError, .noSelection)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testRegistersEverySelectedEligibleCandidateOnceAndCopiesFinalValues() throws {
        let context = try makeContext()
        let first = candidate(
            id: id(1),
            key: "first",
            title: "Team sync",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: ClockTime(hour: 14, minute: 30),
            timeZoneIdentifier: "Asia/Seoul",
            notifyDayBefore: true,
            calendarExportRequested: true
        )
        let sameDate = candidate(
            id: id(2),
            key: "same-date",
            title: "Dinner",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            notifySameDay: true
        )
        let unselected = candidate(id: id(3), key: "unselected", title: "Unselected")
        let dismissed = candidate(id: id(4), key: "dismissed", title: "Dismissed", status: .dismissed)
        [first, sameDate, unselected, dismissed].forEach(context.insert)
        try context.save()
        let registeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let service = ScheduleRegistrationService(
            context: context,
            now: { registeredAt },
            widgetSnapshotRefresh: {}
        )

        let result = try service.register(candidateIDs: [sameDate.id, first.id])

        XCTAssertEqual(result.scheduleIDs.count, 2)
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        XCTAssertEqual(Set(schedules.map(\.sourceCandidateID)), Set([first.id, sameDate.id]))
        XCTAssertTrue(schedules.allSatisfy { $0.date == CalendarDate(year: 2026, month: 10, day: 3) })
        let copiedFirst = try XCTUnwrap(schedules.first { $0.sourceCandidateID == first.id })
        XCTAssertEqual(copiedFirst.title, "Team sync")
        XCTAssertEqual(copiedFirst.time, ClockTime(hour: 14, minute: 30))
        XCTAssertEqual(copiedFirst.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertTrue(copiedFirst.notifyDayBefore)
        XCTAssertFalse(copiedFirst.notifySameDay)
        XCTAssertEqual(copiedFirst.calendarExportStatus, .pending)
        XCTAssertEqual(copiedFirst.createdAt, registeredAt)
        XCTAssertEqual(copiedFirst.updatedAt, registeredAt)
        XCTAssertEqual(first.reviewStatus, .registered)
        XCTAssertEqual(first.registeredScheduleID, copiedFirst.id)
        XCTAssertEqual(sameDate.reviewStatus, .registered)
        XCTAssertNil(unselected.registeredScheduleID)
        XCTAssertEqual(unselected.reviewStatus, .pending)
        XCTAssertNil(dismissed.registeredScheduleID)
        XCTAssertEqual(dismissed.reviewStatus, .dismissed)
    }

    func testAllDayScheduleStoresRegistrationTimeZoneForReminderPlanning() throws {
        let context = try makeContext()
        let selected = candidate(id: id(9), key: "all-day", title: "All day")
        context.insert(selected)
        try context.save()
        let service = ScheduleRegistrationService(
            context: context,
            timeZone: { TimeZone(identifier: "Asia/Seoul")! },
            widgetSnapshotRefresh: {}
        )

        _ = try service.register(candidateIDs: [selected.id])

        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertNil(schedule.time)
        XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Seoul")
    }

    func testSuccessfulRegistrationRefreshesWidgetSnapshotAfterSaving() throws {
        let context = try makeContext()
        let selected = candidate(id: id(10), key: "widget", title: "Widget")
        context.insert(selected)
        try context.save()
        var events: [String] = []
        let service = ScheduleRegistrationService(
            context: context,
            save: { context in
                try context.save()
                events.append("saved")
            },
            widgetSnapshotRefresh: {
                events.append("refreshed")
            }
        )

        _ = try service.register(candidateIDs: [selected.id])

        XCTAssertEqual(events, ["saved", "refreshed"])
    }

    func testWidgetSnapshotFailureDoesNotRollBackSuccessfulRegistration() throws {
        let context = try makeContext()
        let selected = candidate(id: id(11), key: "widget-failure", title: "Still saved")
        context.insert(selected)
        try context.save()
        let service = ScheduleRegistrationService(
            context: context,
            widgetSnapshotRefresh: { throw TestError.saveFailed }
        )

        let result = try service.register(candidateIDs: [selected.id])

        XCTAssertEqual(result.scheduleIDs.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
        XCTAssertEqual(selected.reviewStatus, .registered)
    }

    func testAnyInvalidOrStaleSelectionBlocksTheWholeBatch() throws {
        let context = try makeContext()
        let valid = candidate(id: id(1), key: "valid", title: "Valid")
        let needsReview = candidate(
            id: id(2),
            key: "review",
            title: "Needs review",
            reviewReasons: [.ambiguousDate]
        )
        let dismissed = candidate(id: id(3), key: "dismissed", title: "Dismissed", status: .dismissed)
        [valid, needsReview, dismissed].forEach(context.insert)
        try context.save()
        let missingID = id(4)
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})

        XCTAssertThrowsError(
            try service.register(candidateIDs: [valid.id, needsReview.id, dismissed.id, missingID])
        ) { error in
            XCTAssertEqual(
                error as? ScheduleRegistrationError,
                .validationFailed([
                    ScheduleRegistrationIssue(candidateID: needsReview.id, reason: .needsReview),
                    ScheduleRegistrationIssue(candidateID: dismissed.id, reason: .notPending),
                    ScheduleRegistrationIssue(candidateID: missingID, reason: .unavailable),
                ])
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        XCTAssertEqual(valid.reviewStatus, .pending)
        XCTAssertNil(valid.registeredScheduleID)
    }

    func testRepeatedRequestCannotCreateDuplicateSchedule() throws {
        let context = try makeContext()
        let selected = candidate(id: id(1), key: "selected", title: "Selected")
        context.insert(selected)
        try context.save()
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})

        _ = try service.register(candidateIDs: [selected.id])

        XCTAssertThrowsError(try service.register(candidateIDs: [selected.id])) { error in
            XCTAssertEqual(
                error as? ScheduleRegistrationError,
                .validationFailed([
                    ScheduleRegistrationIssue(candidateID: selected.id, reason: .alreadyRegistered)
                ])
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testSaveFailureRollsBackEveryScheduleAndCandidateThenRetrySucceeds() throws {
        let context = try makeContext()
        let first = candidate(id: id(1), key: "first", title: "First")
        let second = candidate(id: id(2), key: "second", title: "Second")
        [first, second].forEach(context.insert)
        try context.save()
        var shouldFail = true
        var refreshCount = 0
        let service = ScheduleRegistrationService(
            context: context,
            save: { context in
                if shouldFail {
                    shouldFail = false
                    throw TestError.saveFailed
                }
                try context.save()
            },
            widgetSnapshotRefresh: { refreshCount += 1 }
        )

        XCTAssertThrowsError(try service.register(candidateIDs: [first.id, second.id])) {
            XCTAssertEqual($0 as? ScheduleRegistrationError, .saveFailed)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        XCTAssertEqual(first.reviewStatus, .pending)
        XCTAssertEqual(second.reviewStatus, .pending)
        XCTAssertNil(first.registeredScheduleID)
        XCTAssertNil(second.registeredScheduleID)
        XCTAssertEqual(refreshCount, 0)

        let retry = try service.register(candidateIDs: [first.id, second.id])

        XCTAssertEqual(retry.scheduleIDs.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 2)
    }

    func testRegistrationPersistsAfterReopeningStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "SnapSchedule.store")
        let candidateID = id(1)
        var scheduleID: UUID?

        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.autosaveEnabled = false
            context.insert(candidate(id: candidateID, key: "persisted", title: "Persisted"))
            try context.save()
            scheduleID = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
                .register(candidateIDs: [candidateID])
                .scheduleIDs
                .first
        }

        let reopenedContext = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let reopenedCandidate = try XCTUnwrap(
            try reopenedContext.fetch(FetchDescriptor<ScheduleCandidate>()).first
        )
        let reopenedSchedule = try XCTUnwrap(
            try reopenedContext.fetch(FetchDescriptor<Schedule>()).first
        )
        XCTAssertEqual(reopenedCandidate.reviewStatus, .registered)
        XCTAssertEqual(reopenedCandidate.registeredScheduleID, scheduleID)
        XCTAssertEqual(reopenedSchedule.id, scheduleID)
        XCTAssertEqual(reopenedSchedule.sourceCandidateID, candidateID)
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        return context
    }

    private func candidate(
        id: UUID,
        key: String,
        title: String,
        date: CalendarDate = CalendarDate(year: 2026, month: 10, day: 3),
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        reviewReasons: [CandidateReviewReason] = [],
        notifyDayBefore: Bool = false,
        notifySameDay: Bool = false,
        calendarExportRequested: Bool = false,
        status: CandidateReviewStatus = .pending
    ) -> ScheduleCandidate {
        ScheduleCandidate(
            id: id,
            sourceAssetIdentifier: "asset-\(key)",
            sourceCandidateKey: key,
            title: title,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            reviewReasons: reviewReasons,
            notifyDayBefore: notifyDayBefore,
            notifySameDay: notifySameDay,
            calendarExportRequested: calendarExportRequested,
            reviewStatus: status
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "15000000-0000-0000-0000-%012d", value))!
    }
}
