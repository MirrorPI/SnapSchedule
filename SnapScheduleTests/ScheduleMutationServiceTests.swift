import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class ScheduleMutationServiceTests: XCTestCase {
    private enum TestError: Error { case saveFailed }

    func testUpdatePersistsTrimmedValuesAndTimeRemovalAfterReopeningStore() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduleID = id(1)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.autosaveEnabled = false
            let schedule = makeSchedule(id: scheduleID)
            context.insert(schedule)
            try context.save()
            var draft = ScheduleEditDraft(schedule: schedule)
            draft.title = "  Updated title\n"
            draft.date = CalendarDate(year: 2027, month: 2, day: 3)
            draft.includesTime = false
            draft.notifyDayBefore = false
            draft.notifySameDay = true

            let result = try ScheduleMutationService(
                context: context,
                now: { updatedAt },
                widgetSnapshotRefresh: {}
            )
                .update(scheduleID: scheduleID, draft: draft)

            XCTAssertEqual(result, ScheduleMutationResult(scheduleID: scheduleID, kind: .updated))
        }

        let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(stored.title, "Updated title")
        XCTAssertEqual(stored.date, CalendarDate(year: 2027, month: 2, day: 3))
        XCTAssertNil(stored.time)
        XCTAssertEqual(stored.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertFalse(stored.notifyDayBefore)
        XCTAssertTrue(stored.notifySameDay)
        XCTAssertEqual(stored.updatedAt, updatedAt)
        XCTAssertEqual(stored.calendarExportStatus, .succeeded)
    }

    func testEditingDraftWithoutSavingDoesNotMutateSchedule() {
        let schedule = makeSchedule(id: id(2))
        var draft = ScheduleEditDraft(schedule: schedule)

        draft.title = "Changed"
        draft.date = CalendarDate(year: 2028, month: 1, day: 1)
        draft.includesTime = false

        XCTAssertEqual(schedule.title, "Original")
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 3))
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 30))
        XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Seoul")
    }

    func testDraftDetectsEitherReminderBeingNewlyEnabled() {
        let schedule = makeSchedule(id: id(7))
        var draft = ScheduleEditDraft(schedule: schedule)

        XCTAssertFalse(draft.enablesNotification(comparedTo: schedule))

        draft.notifySameDay = true
        XCTAssertTrue(draft.enablesNotification(comparedTo: schedule))

        schedule.notifyDayBefore = false
        draft.notifyDayBefore = true
        draft.notifySameDay = false
        XCTAssertTrue(draft.enablesNotification(comparedTo: schedule))
    }

    func testSuccessfulUpdateAndDeleteRefreshWidgetSnapshotAfterSaving() throws {
        let context = try makeContext()
        let schedule = makeSchedule(id: id(8))
        context.insert(schedule)
        try context.save()
        var events: [String] = []
        let service = ScheduleMutationService(
            context: context,
            save: { context in
                try context.save()
                events.append("saved")
            },
            widgetSnapshotRefresh: {
                events.append("refreshed")
            }
        )
        var draft = ScheduleEditDraft(schedule: schedule)
        draft.title = "Updated"

        _ = try service.update(scheduleID: schedule.id, draft: draft)
        _ = try service.delete(scheduleID: schedule.id)

        XCTAssertEqual(events, ["saved", "refreshed", "saved", "refreshed"])
    }

    func testWidgetSnapshotFailureDoesNotRollBackSuccessfulUpdateOrDelete() throws {
        let context = try makeContext()
        let schedule = makeSchedule(id: id(9))
        context.insert(schedule)
        try context.save()
        let service = ScheduleMutationService(
            context: context,
            widgetSnapshotRefresh: { throw TestError.saveFailed }
        )
        var draft = ScheduleEditDraft(schedule: schedule)
        draft.title = "Updated"

        let update = try service.update(scheduleID: schedule.id, draft: draft)
        XCTAssertEqual(schedule.title, "Updated")
        XCTAssertTrue(update.widgetRefreshFailed, "The caller must be able to disclose and retry a failed widget refresh")

        let deletion = try service.delete(scheduleID: schedule.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        XCTAssertTrue(deletion.widgetRefreshFailed)
    }

    func testInvalidEditsAreRejectedBeforeMutatingStoredSchedule() throws {
        let context = try makeContext()
        let schedule = makeSchedule(id: id(3))
        context.insert(schedule)
        try context.save()
        let service = ScheduleMutationService(context: context, widgetSnapshotRefresh: {})

        var blankTitle = ScheduleEditDraft(schedule: schedule)
        blankTitle.title = " \n "
        XCTAssertThrowsError(try service.update(scheduleID: schedule.id, draft: blankTitle)) {
            XCTAssertEqual($0 as? ScheduleMutationError, .blankTitle)
        }

        var invalidDate = ScheduleEditDraft(schedule: schedule)
        invalidDate.date = CalendarDate(year: 2026, month: 2, day: 30)
        XCTAssertThrowsError(try service.update(scheduleID: schedule.id, draft: invalidDate)) {
            XCTAssertEqual($0 as? ScheduleMutationError, .invalidDate)
        }

        var invalidTimeZone = ScheduleEditDraft(schedule: schedule)
        invalidTimeZone.timeZoneIdentifier = "Mars/Olympus"
        XCTAssertThrowsError(try service.update(scheduleID: schedule.id, draft: invalidTimeZone)) {
            XCTAssertEqual($0 as? ScheduleMutationError, .invalidTimeZone)
        }

        XCTAssertEqual(schedule.title, "Original")
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 3))
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 30))
    }

    func testWidgetRetryRegeneratesCommittedEditWithoutRepeatingTheMutation() throws {
        let context = try makeContext()
        let schedule = makeSchedule(id: id(10))
        context.insert(schedule)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var shouldFail = true
        var saveCount = 0
        let snapshotStore = WidgetSnapshotStore(
            containerURL: { directory },
            now: { Date(timeIntervalSince1970: 0) },
            atomicWrite: { data, url in
                if shouldFail { throw TestError.saveFailed }
                try data.write(to: url, options: .atomic)
            },
            timelineReload: {}
        )
        let service = ScheduleMutationService(
            context: context,
            save: { context in
                try context.save()
                saveCount += 1
            },
            widgetSnapshotRefresh: {
                _ = try snapshotStore.write(schedules: context.fetch(FetchDescriptor<Schedule>()))
            }
        )
        var draft = ScheduleEditDraft(schedule: schedule)
        draft.title = "Committed new title"
        let result = try service.update(scheduleID: schedule.id, draft: draft)
        XCTAssertTrue(result.widgetRefreshFailed)
        XCTAssertEqual(snapshotStore.read(), .missing)
        XCTAssertThrowsError(try service.retryWidgetSnapshotRefresh())

        shouldFail = false
        try service.retryWidgetSnapshotRefresh()

        guard case let .success(snapshot) = snapshotStore.read() else {
            return XCTFail("Retry must publish the committed schedule")
        }
        XCTAssertEqual(snapshot.schedules.map(\.title), ["Committed new title"])
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testDeletePreservesRegisteredCandidateAndCompletedScan() throws {
        let context = try makeContext()
        let scheduleID = id(4)
        let candidate = ScheduleCandidate(
            id: id(40),
            sourceAssetIdentifier: "asset-4",
            sourceCandidateKey: "candidate-4",
            title: "Original",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            reviewStatus: .registered,
            registeredScheduleID: scheduleID
        )
        let scan = ScreenshotScan(
            assetIdentifier: "asset-4",
            status: .completed,
            analyzedAt: Date(timeIntervalSince1970: 1_700_000_000),
            analysisVersion: "1",
            hasDateCandidates: true
        )
        context.insert(candidate)
        context.insert(scan)
        context.insert(makeSchedule(id: scheduleID, sourceCandidateID: candidate.id, sourceAssetIdentifier: "asset-4"))
        try context.save()

        let result = try ScheduleMutationService(context: context, widgetSnapshotRefresh: {})
            .delete(scheduleID: scheduleID)

        XCTAssertEqual(result, ScheduleMutationResult(scheduleID: scheduleID, kind: .deleted))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        let storedCandidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(storedCandidate.reviewStatus, .registered)
        XCTAssertEqual(storedCandidate.registeredScheduleID, scheduleID)
        let storedScan = try XCTUnwrap(try context.fetch(FetchDescriptor<ScreenshotScan>()).first)
        XCTAssertEqual(storedScan.status, .completed)
        XCTAssertTrue(storedScan.hasDateCandidates == true)
    }

    func testDeleteRemainsDeletedAfterReopeningStore() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduleID = id(6)

        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.autosaveEnabled = false
            context.insert(makeSchedule(id: scheduleID))
            try context.save()
            _ = try ScheduleMutationService(context: context, widgetSnapshotRefresh: {})
                .delete(scheduleID: scheduleID)
        }

        let reopenedContext = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testSaveFailureRollsBackUpdateAndDelete() throws {
        let context = try makeContext()
        let schedule = makeSchedule(id: id(5))
        context.insert(schedule)
        try context.save()
        var refreshCount = 0
        let service = ScheduleMutationService(
            context: context,
            save: { _ in throw TestError.saveFailed },
            widgetSnapshotRefresh: { refreshCount += 1 }
        )
        var draft = ScheduleEditDraft(schedule: schedule)
        draft.title = "Changed"

        XCTAssertThrowsError(try service.update(scheduleID: schedule.id, draft: draft)) {
            XCTAssertEqual($0 as? ScheduleMutationError, .saveFailed)
        }
        let afterUpdate = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(afterUpdate.title, "Original")

        XCTAssertThrowsError(try service.delete(scheduleID: schedule.id)) {
            XCTAssertEqual($0 as? ScheduleMutationError, .saveFailed)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
        XCTAssertEqual(refreshCount, 0)
    }

    private func makeSchedule(
        id: UUID,
        sourceCandidateID: UUID? = nil,
        sourceAssetIdentifier: String = "asset-original"
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: sourceCandidateID ?? self.id(100),
            title: "Original",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: ClockTime(hour: 14, minute: 30),
            timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: sourceAssetIdentifier,
            notifyDayBefore: true,
            calendarExportStatus: .succeeded,
            calendarEventIdentifier: "event-1"
        )
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        return context
    }

    private func makeStoreLocation() throws -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "SnapSchedule.store"))
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "18000000-0000-0000-0000-%012d", value))!
    }
}
