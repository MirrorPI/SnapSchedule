import Foundation
import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class CalendarExportServiceTests: XCTestCase {
    private enum TestError: Error {
        case requestFailed
        case saveFailed
        case localSaveFailed
    }

    func testDeletedScheduleDuringCalendarPermissionDoesNotCreateExternalCopy() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        let id = schedule.id
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .notDetermined)
        writer.requestResult = .writeOnly
        writer.onRequest = {
            context.delete(schedule)
            try context.save()
        }
        let result = await CalendarExportService(context: context, writer: writer).export(scheduleID: id)
        XCTAssertEqual(result, .failed(.unavailable))
        XCTAssertEqual(writer.saveAttemptCount, 0, "A deleted schedule cannot be sent after a suspended permission request")
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testCalendarPermissionCompletionUsesCurrentSavedScheduleContent() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        schedule.time = nil
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .notDetermined)
        writer.requestResult = .writeOnly
        writer.onRequest = {
            schedule.title = "Corrected title before granting access"
            schedule.date = CalendarDate(year: 2027, month: 2, day: 15)
            try context.save()
        }
        let result = await CalendarExportService(context: context, writer: writer).export(scheduleID: schedule.id)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(writer.savedEvents.single?.title, "Corrected title before granting access")
        XCTAssertEqual(writer.savedEvents.single?.startDate, instant(2027, 2, 15, 0, 0, timeZone: "Asia/Seoul"))
    }

    func testAllDayExportUsesLocalMidnightAndExclusiveNextDayWithoutAlarms() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: nil,
            timeZoneIdentifier: "Asia/Seoul",
            status: .pending
        )
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)

        let result = await CalendarExportService(context: context, writer: writer)
            .export(scheduleID: schedule.id)

        XCTAssertEqual(result, .succeeded)
        let event = try XCTUnwrap(writer.savedEvents.single)
        XCTAssertEqual(event.title, "Team sync")
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(event.startDate, instant(2026, 10, 3, 0, 0, timeZone: "Asia/Seoul"))
        XCTAssertEqual(event.endDate, instant(2026, 10, 4, 0, 0, timeZone: "Asia/Seoul"))
        XCTAssertTrue(event.alarms.isEmpty)
    }

    func testTimedExportUsesStoredTimeZoneAndOneHourDuration() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: ClockTime(hour: 14, minute: 30),
            timeZoneIdentifier: "America/Los_Angeles",
            status: .pending
        )
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .fullAccess)

        let result = await CalendarExportService(context: context, writer: writer)
            .export(scheduleID: schedule.id)

        XCTAssertEqual(result, .succeeded)
        let event = try XCTUnwrap(writer.savedEvents.single)
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(event.startDate, instant(2026, 10, 3, 14, 30, timeZone: "America/Los_Angeles"))
        XCTAssertEqual(event.endDate, instant(2026, 10, 3, 15, 30, timeZone: "America/Los_Angeles"))
        XCTAssertTrue(event.alarms.isEmpty)
    }

    func testNotDeterminedRequestsWriteOnlyAndPersistsRunningBeforeExternalSave() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .notDetermined)
        writer.requestResult = .writeOnly
        writer.onSave = {
            XCTAssertEqual(schedule.calendarExportStatus, .exporting)
            XCTAssertTrue(context.hasChanges == false)
        }

        let result = await CalendarExportService(context: context, writer: writer)
            .export(scheduleID: schedule.id)

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(writer.requestCount, 1)
        XCTAssertEqual(writer.savedEvents.count, 1)
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
        XCTAssertEqual(schedule.calendarEventIdentifier, "event-1")
        XCTAssertNil(schedule.calendarExportFailureMessage)
    }

    func testDeniedPermissionIsClearFailureAndKeepsInternalSchedule() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .denied)

        let result = await CalendarExportService(context: context, writer: writer)
            .export(scheduleID: schedule.id)

        XCTAssertEqual(result, .failed(.accessDenied))
        XCTAssertEqual(writer.savedEvents.count, 0)
        XCTAssertEqual(schedule.calendarExportStatus, .failed)
        XCTAssertNotNil(schedule.calendarExportFailureMessage)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testClearSaveFailureCanBeRetriedAndThenSucceeds() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        writer.saveError = TestError.saveFailed
        let service = CalendarExportService(context: context, writer: writer)

        let firstResult = await service.export(scheduleID: schedule.id)
        XCTAssertEqual(firstResult, .failed(.eventSaveFailed))
        XCTAssertEqual(schedule.calendarExportStatus, .failed)

        writer.saveError = nil
        let retryResult = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(retryResult, .succeeded)
        XCTAssertEqual(writer.saveAttemptCount, 2)
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
    }

    func testSucceededScheduleDoesNotCreateDuplicateOnRepeatedRequest() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        let service = CalendarExportService(context: context, writer: writer)

        let firstResult = await service.export(scheduleID: schedule.id)
        let repeatedResult = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(firstResult, .succeeded)
        XCTAssertEqual(repeatedResult, .alreadySucceeded)
        XCTAssertEqual(writer.saveAttemptCount, 1)
    }

    func testInterruptedRunningExportBecomesUnknownAfterRecovery() throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .exporting)
        context.insert(schedule)
        try context.save()

        let count = try CalendarExportService(context: context, writer: FakeCalendarEventWriter())
            .recoverInterruptedExports()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(schedule.calendarExportStatus, .unknown)
        XCTAssertNotNil(schedule.calendarExportFailureMessage)
        XCTAssertFalse(context.hasChanges)
    }

    func testUnknownExportRequiresDuplicateRiskConfirmationBeforeRetry() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .unknown)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        let service = CalendarExportService(context: context, writer: writer)

        let blocked = await service.export(scheduleID: schedule.id)
        XCTAssertEqual(blocked, .confirmationRequired)
        XCTAssertEqual(writer.saveAttemptCount, 0)

        let retried = await service.export(
            scheduleID: schedule.id,
            confirmUnknownDuplicateRisk: true
        )
        XCTAssertEqual(retried, .succeeded)
        XCTAssertEqual(writer.saveAttemptCount, 1)
    }

    func testExternalSuccessWithFinalLocalSaveFailureBecomesUnknown() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        var saveCount = 0
        let service = CalendarExportService(
            context: context,
            writer: writer,
            save: { context in
                saveCount += 1
                if saveCount == 2 {
                    throw TestError.localSaveFailed
                }
                try context.save()
            }
        )

        let result = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(writer.saveAttemptCount, 1)
        XCTAssertEqual(schedule.calendarExportStatus, .unknown)
    }

    func testInitialLocalStateFailureNeverCallsExternalCalendar() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        let service = CalendarExportService(
            context: context,
            writer: writer,
            save: { _ in throw TestError.localSaveFailed }
        )

        let result = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(result, .failed(.localStateSaveFailed))
        XCTAssertEqual(writer.saveAttemptCount, 0)
    }

    func testBatchExportsOnlyRequestedSchedules() async throws {
        let context = try makeContext()
        let requested = makeSchedule(id: id(1), status: .pending)
        let notRequested = makeSchedule(id: id(2), status: .notRequested)
        context.insert(requested)
        context.insert(notRequested)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)

        let summary = try await CalendarExportService(context: context, writer: writer)
            .exportRequested(scheduleIDs: [requested.id, notRequested.id])

        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(writer.saveAttemptCount, 1)
        XCTAssertEqual(requested.calendarExportStatus, .succeeded)
        XCTAssertEqual(notRequested.calendarExportStatus, .notRequested)
    }

    func testResumePendingExportsProcessesPersistedIntentAfterRelaunch() async throws {
        let context = try makeContext()
        let pending = makeSchedule(id: id(3), status: .pending)
        let notRequested = makeSchedule(id: id(4), status: .notRequested)
        context.insert(pending)
        context.insert(notRequested)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)

        let summary = try await CalendarExportService(context: context, writer: writer)
            .resumePendingExports()

        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(writer.saveAttemptCount, 1)
        XCTAssertEqual(pending.calendarExportStatus, .succeeded)
        XCTAssertEqual(notRequested.calendarExportStatus, .notRequested)
    }

    func testExportingRecoverySaveFailureReturnsActionableFailureWithoutExternalWrite() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .exporting)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .writeOnly)
        let service = CalendarExportService(
            context: context,
            writer: writer,
            save: { _ in throw TestError.localSaveFailed }
        )

        let result = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(result, .failed(.localStateSaveFailed))
        XCTAssertEqual(writer.saveAttemptCount, 0)
    }

    func testClearFailureStateSaveFailureDoesNotClaimDuplicateRiskUnknown() async throws {
        let context = try makeContext()
        let schedule = makeSchedule(status: .pending)
        context.insert(schedule)
        try context.save()
        let writer = FakeCalendarEventWriter(access: .denied)
        var saveCount = 0
        let service = CalendarExportService(
            context: context,
            writer: writer,
            save: { context in
                saveCount += 1
                if saveCount == 2 { throw TestError.localSaveFailed }
                try context.save()
            }
        )

        let result = await service.export(scheduleID: schedule.id)

        XCTAssertEqual(result, .failed(.localStateSaveFailed))
        XCTAssertEqual(schedule.calendarExportStatus, .failed)
        XCTAssertEqual(writer.saveAttemptCount, 0)
        XCTAssertFalse(schedule.calendarExportFailureMessage?.contains("duplicate") == true)
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        return context
    }

    private func makeSchedule(
        id: UUID = UUID(),
        date: CalendarDate = CalendarDate(year: 2026, month: 10, day: 3),
        time: ClockTime? = ClockTime(hour: 14, minute: 30),
        timeZoneIdentifier: String = "Asia/Seoul",
        status: CalendarExportStatus
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: UUID(),
            title: "Team sync",
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            sourceAssetIdentifier: "asset-1",
            calendarExportStatus: status
        )
    }

    private func instant(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone identifier: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "22000000-0000-0000-0000-%012d", value))!
    }
}

@MainActor
private final class FakeCalendarEventWriter: CalendarEventWriting {
    var access: CalendarAuthorizationAccess
    var requestResult: CalendarAuthorizationAccess
    var requestError: Error?
    var saveError: Error?
    var requestCount = 0
    var saveAttemptCount = 0
    var savedEvents: [CalendarEventDraft] = []
    var onRequest: (() throws -> Void)?
    var onSave: (() -> Void)?

    init(access: CalendarAuthorizationAccess = .writeOnly) {
        self.access = access
        requestResult = access
    }

    func requestWriteOnlyAccess() async throws -> CalendarAuthorizationAccess {
        requestCount += 1
        try onRequest?()
        if let requestError { throw requestError }
        access = requestResult
        return requestResult
    }

    func save(_ event: CalendarEventDraft) throws -> String? {
        saveAttemptCount += 1
        onSave?()
        if let saveError { throw saveError }
        savedEvents.append(event)
        return "event-\(savedEvents.count)"
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? first : nil
    }
}
