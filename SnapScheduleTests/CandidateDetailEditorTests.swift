import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import SnapSchedule

@MainActor
final class CandidateDetailEditorTests: XCTestCase {
    func testAddDateUsesNextUnusedRecognizedDayAndLeavesExhaustedRowBlank() {
        let first = CalendarDate(year: 2026, month: 10, day: 18)
        let second = CalendarDate(year: 2026, month: 10, day: 20)
        let third = CalendarDate(year: 2026, month: 10, day: 22)
        let candidate = makeCandidate(id: UUID(), title: "Meeting", date: first)
        candidate.recognizedDateOptions = [
            CandidateDateEntry(date: first),
            CandidateDateEntry(date: second, time: ClockTime(hour: 9, minute: 0),
                timeZoneIdentifier: "Asia/Tokyo", reviewReasons: [.uncertainTimeAssociation, .timeZoneInferred]),
            CandidateDateEntry(date: third)
        ]
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertEqual(draft.dateEntries.count, 1)
        draft.addDate()
        XCTAssertEqual(draft.dateEntries[1].date, second)
        XCTAssertEqual(draft.dateEntries[1].time, ClockTime(hour: 9, minute: 0))
        XCTAssertEqual(draft.dateEntries[1].timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(draft.dateEntries[1].remainingReviewReasons, [.uncertainTimeAssociation])
        XCTAssertFalse(draft.isRegistrationEligible, "Adding a parsed date cannot confirm uncertain meaning")
        draft.addDate()
        XCTAssertEqual(draft.dateEntries[2].date, third)
        XCTAssertNil(draft.dateEntries[2].time, "A date-only recognition cannot borrow another row's time")
        draft.addDate()
        XCTAssertNil(draft.dateEntries[3].date)
        XCTAssertNil(draft.dateEntries[3].time)
        XCTAssertEqual(draft.dateEntries[0].date, first)
        XCTAssertEqual(candidate.dateEntries.count, 1, "Adding only changes the draft until saving")
    }

    func testAddDateSkipsUsedDaysEvenWithDifferentTimesAndInvalidRecognitions() {
        let date = CalendarDate(year: 2026, month: 10, day: 18)
        let candidate = makeCandidate(id: UUID(), title: "Meeting", date: date,
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")
        candidate.recognizedDateOptions = [
            CandidateDateEntry(date: date, time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "Asia/Tokyo"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 2, day: 30)),
            CandidateDateEntry(time: ClockTime(hour: 17, minute: 0))
        ]
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.addDate()
        XCTAssertNil(draft.dateEntries[1].date)
        XCTAssertNil(draft.dateEntries[1].time)
        // Same-day events remain possible through deliberate manual input.
        draft.dateEntries[1].date = date
        draft.dateEntries[1].time = ClockTime(hour: 9, minute: 0)
        draft.dateEntries[1].timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertFalse(draft.hasDuplicateDates)
        XCTAssertTrue(draft.isRegistrationEligible)
    }

    func testRemovedRecognizedDateCanBeAddedAgainWithANewIndependentRowID() {
        let candidate = makeCandidate(id: UUID(), title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 18))
        let option = CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20))
        candidate.recognizedDateOptions = [CandidateDateEntry(date: candidate.date), option]
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.addDate()
        let removedID = draft.dateEntries[1].id
        XCTAssertEqual(draft.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertNotEqual(removedID, option.id)
        draft.removeDate(id: removedID)
        draft.addDate()
        XCTAssertEqual(draft.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertNotEqual(draft.dateEntries[1].id, removedID)
        XCTAssertNotEqual(draft.dateEntries[1].id, option.id)
        XCTAssertEqual(candidate.recognizedDateOptions.count, 2)
    }

    func testAddRecognizedDateUsesEditedAndRestoredRowsWithoutConsumingOriginalOptions() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        var rowID: UUID!
        try autoreleasepool {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
            context.autosaveEnabled = false
            let candidate = makeCandidate(id: UUID(), title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 18))
            candidate.recognizedDateOptions = [18, 20, 22].map { CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: $0)) }
            context.insert(candidate); try context.save()
            var draft = CandidateDetailDraft(candidate: candidate)
            draft.addDate()
            XCTAssertEqual(draft.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
            draft.dateEntries[1].date = CalendarDate(year: 2026, month: 10, day: 22)
            rowID = draft.dateEntries[1].id
            try draft.saveUnregistered(to: candidate, in: context)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        var restored = CandidateDetailDraft(candidate: candidate)
        XCTAssertEqual(restored.dateEntries[1].id, rowID)
        restored.addDate()
        XCTAssertEqual(restored.dateEntries[2].date, CalendarDate(year: 2026, month: 10, day: 20))
        restored.addDate()
        XCTAssertNil(restored.dateEntries[3].date)
        XCTAssertEqual(candidate.recognizedDateOptions.map(\.date), [18, 20, 22].map { CalendarDate(year: 2026, month: 10, day: $0) })
    }

    func testFirstAllDayRowKeepsItsChosenZoneAfterReopenAndRegistration() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try autoreleasepool {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
            let candidate = makeCandidate(id: UUID(), title: "All day", date: CalendarDate(year: 2026, month: 10, day: 18))
            context.insert(candidate); try context.save()
            var draft = CandidateDetailDraft(candidate: candidate); draft.timeZoneIdentifier = "Asia/Tokyo"
            try draft.saveUnregistered(to: candidate, in: context)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        var restored = CandidateDetailDraft(candidate: candidate)
        XCTAssertNil(restored.time); XCTAssertEqual(restored.timeZoneIdentifier, "Asia/Tokyo")
        _ = try restored.register(to: candidate, in: context, service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertNil(schedule.time); XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testRemovingFirstRowPreservesSurvivorZoneAndRequiredConfirmation() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory()); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Shared", date: CalendarDate(year: 2026, month: 10, day: 18))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        let firstID = draft.dateEntries[0].id
        draft.dateEntries.append(CandidateDateDraft(entry: CandidateDateEntry(
            date: CalendarDate(year: 2026, month: 10, day: 20), time: ClockTime(hour: 9, minute: 0),
            timeZoneIdentifier: "America/Los_Angeles", reviewReasons: [.uncertainTimeAssociation, .timeZoneInferred])))
        draft.removeDate(id: firstID)
        try draft.saveUnregistered(to: candidate, in: context)
        let reopened = ModelContext(context.container)
        let source = try XCTUnwrap(try reopened.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        var restored = CandidateDetailDraft(candidate: source)
        XCTAssertEqual(restored.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertFalse(restored.isRegistrationEligible)
        restored.confirmedReviewReasons.insert(.uncertainTimeAssociation)
        _ = try restored.register(to: source, in: reopened, service: ScheduleRegistrationService(context: reopened, widgetSnapshotRefresh: {}))
        let schedule = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(schedule.time, ClockTime(hour: 9, minute: 0))
        XCTAssertEqual(schedule.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(source.reviewReasons, [.timeZoneInferred])
        XCTAssertEqual(schedule.sourceCandidateID, candidate.id)
    }
    func testOtherContextStateChangeCannotBeOverwrittenByEditorSaveOrRegister() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let container = try SnapScheduleModelContainer.make(url: location.storeURL)
        let context = ModelContext(container); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Original", date: CalendarDate(year: 2026, month: 10, day: 18))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = "Uncommitted edit"; draft.addDate(); draft.dateEntries[1].date = CalendarDate(year: 2026, month: 10, day: 20)
        let other = ModelContext(container); other.autosaveEnabled = false
        let changed = try XCTUnwrap(try other.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        changed.reviewStatus = .dismissed; try other.save()
        XCTAssertThrowsError(try draft.saveUnregistered(to: candidate, in: context))
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
        let stored = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(stored.title, "Original"); XCTAssertEqual(stored.dateEntries.count, 1)
        XCTAssertEqual(stored.reviewStatus, .dismissed)
        XCTAssertEqual(draft.title, "Uncommitted edit"); XCTAssertEqual(draft.dateEntries.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }
    func testRemovingOriginalDateStillKeepsIncompletePhotoDraftVisibleForRetry() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory()); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Keep editing", date: CalendarDate(year: 2026, month: 10, day: 18))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        let originalID = draft.dateEntries[0].id
        draft.addDate(); draft.removeDate(id: originalID)
        try draft.saveUnregistered(to: candidate, in: context)
        XCTAssertNil(candidate.date)
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(CandidateListPresentation.pending([candidate]).map(\.id), [candidate.id], "An incomplete saved row must remain reachable")
        XCTAssertEqual(CandidateReviewSummary(candidates: [candidate]).pendingCount, 1)
        XCTAssertFalse(candidate.isRegistrationEligible)
        XCTAssertEqual(CandidateDetailDraft(candidate: candidate).dateEntries.count, 1)
    }
    func testAdditionalDatesEditRemoveAutosaveAndReopenIndependently() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        var candidateID: UUID!
        var rowID: UUID!
        try autoreleasepool {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
            context.autosaveEnabled = false
            let candidate = makeCandidate(id: UUID(), title: "Shared", date: CalendarDate(year: 2026, month: 10, day: 18),
                time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")
            context.insert(candidate); try context.save(); candidateID = candidate.id
            var draft = CandidateDetailDraft(candidate: candidate)
            XCTAssertEqual(draft.dateEntries.count, 1)
            draft.addDate()
            XCTAssertNil(draft.dateEntries[1].date)
            XCTAssertNil(draft.dateEntries[1].time, "Adding a row must not invent a time")
            draft.dateEntries[1].date = CalendarDate(year: 2026, month: 10, day: 20)
            draft.dateEntries[1].time = ClockTime(hour: 9, minute: 0)
            draft.dateEntries[1].timeZoneIdentifier = "America/Los_Angeles"
            rowID = draft.dateEntries[1].id
            draft.addDate()
            draft.removeDate(id: draft.dateEntries[2].id)
            XCTAssertEqual(draft.dateEntries.count, 2)
            try draft.saveUnregistered(to: candidate, in: context)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: location.storeURL))
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(candidate.id, candidateID)
        var restored = CandidateDetailDraft(candidate: candidate)
        XCTAssertEqual(restored.dateEntries.count, 2)
        XCTAssertEqual(restored.dateEntries[1].id, rowID)
        XCTAssertEqual(restored.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(restored.dateEntries[1].time, ClockTime(hour: 9, minute: 0))
        XCTAssertEqual(restored.dateEntries[1].timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(restored.time, ClockTime(hour: 14, minute: 0))
        restored.removeDate(id: restored.dateEntries[0].id)
        restored.removeDate(id: restored.dateEntries[0].id)
        XCTAssertEqual(restored.dateEntries.count, 1)
        XCTAssertEqual(candidate.dateEntries.count, 2, "Draft removal cannot delete saved data before saving")
    }

    func testBatchDraftSaveAndRegistrationFailureKeepAllInputForRetry() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory()); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Original", date: CalendarDate(year: 2026, month: 10, day: 18))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = "Edited"
        draft.addDate(); draft.dateEntries[1].date = CalendarDate(year: 2026, month: 10, day: 20)
        draft.dateEntries[1].timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertThrowsError(try draft.saveUnregistered(to: candidate, in: context, save: { _ in throw NSError(domain: "save", code: 1) }))
        XCTAssertEqual(candidate.title, "Original"); XCTAssertEqual(candidate.dateEntries.count, 1)
        XCTAssertEqual(draft.title, "Edited"); XCTAssertEqual(draft.dateEntries.count, 2)
        try draft.saveUnregistered(to: candidate, in: context)
        let failing = ScheduleRegistrationService(context: context, save: { _ in throw NSError(domain: "save", code: 1) }, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try draft.register(to: candidate, in: context, service: failing))
        XCTAssertEqual(candidate.reviewStatus, .pending); XCTAssertEqual(candidate.dateEntries.count, 2)
        XCTAssertEqual(draft.dateEntries.count, 2); XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        let result = try draft.register(to: candidate, in: context, service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        XCTAssertEqual(result.scheduleIDs.count, 2)
    }

    func testAllRowsAndDuplicatesAreValidatedBeforeSavingOrRegistering() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory()); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Original", date: CalendarDate(year: 2026, month: 10, day: 18))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.addDate()
        XCTAssertFalse(draft.isRegistrationEligible)
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
        XCTAssertEqual(candidate.dateEntries.count, 1)
        draft.dateEntries[1].date = draft.date
        XCTAssertTrue(draft.hasDuplicateDates)
        XCTAssertFalse(draft.isRegistrationEligible)
        draft.dateEntries[1].time = ClockTime(hour: 9, minute: 0)
        draft.dateEntries[1].timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertTrue(draft.isRegistrationEligible)
        candidate.reviewStatus = .dismissed; try context.save()
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
        XCTAssertEqual(candidate.title, "Original")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }
    func testValidInferredTimeZoneRegistersWithoutConfirmationAndKeepsProvenance() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory()); context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 8), time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.timeZoneInferred])
        context.insert(candidate); try context.save()
        XCTAssertTrue(candidate.isRegistrationEligible); XCTAssertFalse(candidate.requiresReview)
        XCTAssertTrue(candidate.isSelectedByDefault)
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertTrue(draft.confirmedReviewReasons.isEmpty); XCTAssertTrue(draft.remainingReviewReasons.isEmpty)
        XCTAssertTrue(draft.isRegistrationEligible)
        try draft.saveUnregistered(to: candidate, in: context, save: { _ in XCTFail("Reading and leaving an unchanged candidate cannot rewrite provenance") })
        XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred]); XCTAssertEqual(candidate.evidenceText, "Evidence text")
        let result = try draft.register(to: candidate, in: context, service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        XCTAssertEqual(result.scheduleIDs.count, 1)
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 0)); XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred]); XCTAssertEqual(candidate.evidenceText, "Evidence text")
    }

    func testInferredZoneDoesNotBypassInvalidValuesOrOtherRequiredReviews() throws {
        let candidate = makeCandidate(id: UUID(), title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 8), time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.timeZoneInferred, .uncertainTimeAssociation, .relativeDate])
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertEqual(Set(draft.remainingReviewReasons), [.uncertainTimeAssociation, .relativeDate])
        XCTAssertFalse(draft.isRegistrationEligible)
        draft.confirmedReviewReasons.formUnion([.uncertainTimeAssociation, .relativeDate])
        XCTAssertTrue(draft.isRegistrationEligible)
        draft.timeZoneIdentifier = "Invalid/Zone"; XCTAssertFalse(draft.isRegistrationEligible)
        draft.timeZoneIdentifier = "UTC"; draft.time = ClockTime(hour: 25, minute: 0); XCTAssertFalse(draft.isRegistrationEligible)
        draft.time = ClockTime(hour: 9, minute: 30); XCTAssertTrue(draft.isRegistrationEligible)
        candidate.timeZoneIdentifier = "Invalid/Zone"; candidate.reviewReasons = [.timeZoneInferred]
        XCTAssertFalse(candidate.isRegistrationEligible); XCTAssertTrue(candidate.requiresReview)
    }

    func testUnregisteredAutosavePersistsIncompleteReviewAfterReopeningStore() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let id = try autoreleasepool {
            let container = try SnapScheduleModelContainer.make(url: location.storeURL)
            let context = container.mainContext
            let candidate = makeCandidate(id: UUID(), title: "Before", date: CalendarDate(year: 2030, month: 11, day: 2),
                reviewReasons: [.relativeDate, .missingTime])
            context.insert(candidate); try context.save()
            var draft = CandidateDetailDraft(candidate: candidate)
            draft.title = ""
            draft.notifySameDay = true
            draft.calendarExportRequested = true
            draft.confirmedReviewReasons.insert(.relativeDate)
            XCTAssertEqual(draft.remainingReviewReasons, [.missingTime, .missingTitle])
            try draft.saveUnregistered(to: candidate, in: context)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
            return candidate.id
        }
        let reopened = try SnapScheduleModelContainer.make(url: location.storeURL)
        let saved = try XCTUnwrap(try reopened.mainContext.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.title, "")
        XCTAssertEqual(saved.reviewStatus, .pending)
        XCTAssertNil(saved.registeredScheduleID)
        XCTAssertEqual(saved.reviewReasons, [.missingTime, .missingTitle])
        XCTAssertTrue(saved.notifySameDay)
        XCTAssertTrue(saved.calendarExportRequested)
        XCTAssertNil(saved.time)
        XCTAssertFalse(saved.isRegistrationEligible)
        XCTAssertEqual(CandidateListPresentation.pending([saved]).map(\.id), [id])
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testAutosaveFailureRetainsDraftAndDoesNotOverwriteRegisteredSource() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext; context.autosaveEnabled = false
        let candidate = makeCandidate(id: UUID(), title: "Before", date: CalendarDate(year: 2030, month: 11, day: 2))
        context.insert(candidate); try context.save()
        var draft = CandidateDetailDraft(candidate: candidate); draft.title = "After"
        XCTAssertThrowsError(try draft.saveUnregistered(to: candidate, in: context, save: { _ in throw NSError(domain: "AutosaveFailure", code: 1) }))
        XCTAssertEqual(candidate.title, "Before")
        XCTAssertEqual(draft.title, "After")
        XCTAssertEqual(candidate.reviewStatus, .pending)
        try draft.saveUnregistered(to: candidate, in: context)
        let result = try draft.register(to: candidate, in: context, service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        draft.title = "Stale edit"
        try draft.saveUnregistered(to: candidate, in: context)
        XCTAssertEqual(candidate.title, "After")
        XCTAssertEqual(candidate.registeredScheduleID, result.scheduleIDs.first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
    }

    func testParserFallbackStartsEmptyAndCannotSaveWithoutChoosingTitle() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = makeCandidate(
            id: UUID(), title: "일정 확인 필요",
            date: CalendarDate(year: 2030, month: 11, day: 2),
            reviewReasons: [.missingTitle]
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)

        XCTAssertEqual(draft.title, "")
        XCTAssertFalse(draft.isRegistrationEligible)
        XCTAssertEqual(draft.remainingReviewReasons, [.missingTitle])
        XCTAssertThrowsError(try draft.save(to: candidate, in: context)) {
            XCTAssertEqual($0 as? CandidateDetailValidationError, .blankTitle)
        }
        XCTAssertEqual(candidate.title, "일정 확인 필요")
        XCTAssertThrowsError(try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
            .register(candidateIDs: [candidate.id]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testRecognizedMultilineTitleIsPreservedAndEditableWithoutChangingSourceUntilSave() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = makeCandidate(
            id: UUID(), title: "Conference\nSeoul",
            date: CalendarDate(year: 2030, month: 11, day: 2)
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertEqual(draft.title, "Conference\nSeoul")
        draft.title = "  Conference\nBusan  "
        XCTAssertEqual(candidate.title, "Conference\nSeoul")
        XCTAssertTrue(draft.isRegistrationEligible)
        try draft.save(to: candidate, in: context)
        XCTAssertEqual(candidate.title, "Conference\nBusan")
        XCTAssertTrue(candidate.isRegistrationEligible)
    }

    func testPresetCanBeEditedCancelledSavedReopenedAndRegistered() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidateID = UUID()
        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.autosaveEnabled = false
            let candidate = makeCandidate(
                id: candidateID, title: "일정 확인 필요",
                date: CalendarDate(year: 2030, month: 11, day: 2),
                reviewReasons: [.missingTitle]
            )
            context.insert(candidate)
            try context.save()
            let state = CandidateSelectionState()
            state.synchronize(with: [candidate])
            var cancelled = CandidateDetailDraft(candidate: candidate)
            cancelled.title = "기프티콘"
            XCTAssertTrue(cancelled.isRegistrationEligible)
            XCTAssertEqual(cancelled.remainingReviewReasons, [])
            XCTAssertEqual(candidate.title, "일정 확인 필요")
            XCTAssertEqual(candidate.reviewReasons, [.missingTitle])
            XCTAssertEqual(state.selectedCandidateIDs, [])

            var draft = CandidateDetailDraft(candidate: candidate)
            XCTAssertEqual(draft.title, "")
            // Titles are plain strings in the chosen language, never category IDs.
            for title in ["기프티콘", "지원서", "티켓팅", "이벤트", "Gift voucher", "Application", "Ticket booking", "Event", "ギフト券", "応募書類", "チケット予約", "イベント"] {
                draft.title = title
                XCTAssertTrue(draft.isRegistrationEligible)
                try draft.save(to: candidate, in: context)
                XCTAssertEqual(candidate.title, title)
                XCTAssertTrue(candidate.isRegistrationEligible)
            }
            draft.title = "  ギフト券\nCoffee  "
            try draft.save(to: candidate, in: context)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(candidate.title, "ギフト券\nCoffee")
        XCTAssertTrue(candidate.isRegistrationEligible)
        _ = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
            .register(candidateIDs: [candidateID])
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.title, "ギフト券\nCoffee")
    }

    func testTimeOnlyCandidateBecomesEligibleAfterAddingDateWithoutZoneConfirmation() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidateID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!

        do {
            let container = try SnapScheduleModelContainer.make(url: storeURL)
            let store = LocalDataStore(container: container)
            let candidate = makeCandidate(
                id: candidateID,
                title: "Dinner",
                time: ClockTime(hour: 18, minute: 30),
                timeZoneIdentifier: "Asia/Seoul",
                reviewReasons: [.missingDate, .timeZoneInferred]
            )
            try store.add(candidate)
            var draft = CandidateDetailDraft(candidate: candidate)

            draft.date = CalendarDate(year: 2026, month: 10, day: 5)
            try draft.save(to: candidate, in: store.context)

            XCTAssertTrue(candidate.isRegistrationEligible)
            XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred])
        }

        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(reopened)
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(stored.date, CalendarDate(year: 2026, month: 10, day: 5))
        XCTAssertTrue(stored.isRegistrationEligible)
    }

    func testSavePersistsExplicitConfirmationTimeEditsAndPreferences() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try SnapScheduleModelContainer.make(url: storeURL)
            let context = ModelContext(container)
            let candidate = makeCandidate(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
                title: "Appointment",
                date: CalendarDate(year: 2026, month: 11, day: 2),
                time: ClockTime(hour: 9, minute: 5),
                timeZoneIdentifier: "Asia/Seoul",
                reviewReasons: [.yearInferredFromCaptureDate, .ambiguousTime]
            )
            context.insert(candidate)
            try context.save()
            var draft = CandidateDetailDraft(candidate: candidate)

            draft.confirmedReviewReasons.insert(.yearInferredFromCaptureDate)
            draft.confirmedReviewReasons.insert(.ambiguousTime)
            draft.time = ClockTime(hour: 14, minute: 30)
            draft.timeZoneIdentifier = "UTC"
            draft.notifyDayBefore = true
            draft.notifySameDay = true
            draft.calendarExportRequested = true
            try draft.save(to: candidate, in: context)
        }

        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(reopened)
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(stored.time, ClockTime(hour: 14, minute: 30))
        XCTAssertEqual(stored.timeZoneIdentifier, "UTC")
        XCTAssertEqual(stored.reviewReasons, [])
        XCTAssertTrue(stored.notifyDayBefore)
        XCTAssertTrue(stored.notifySameDay)
        XCTAssertTrue(stored.calendarExportRequested)
        XCTAssertTrue(stored.isRegistrationEligible)
    }

    func testWhitespaceTitleIsRejectedWithoutMutatingStoredCandidate() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let candidate = makeCandidate(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!,
            title: "Original",
            date: CalendarDate(year: 2026, month: 12, day: 1)
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = "  \n "

        XCTAssertThrowsError(try draft.save(to: candidate, in: context)) {
            XCTAssertEqual($0 as? CandidateDetailValidationError, .blankTitle)
        }
        XCTAssertEqual(candidate.title, "Original")
        XCTAssertEqual(candidate.date, CalendarDate(year: 2026, month: 12, day: 1))
    }

    func testMissingOrInvalidDateIsRejectedWithoutReplacingOriginalDate() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let candidate = makeCandidate(
            id: UUID(), title: "Deadline",
            date: CalendarDate(year: 2030, month: 12, day: 1)
        )
        context.insert(candidate)
        try context.save()
        for invalidDate in [nil, CalendarDate(year: 2026, month: 2, day: 30)] {
            var draft = CandidateDetailDraft(candidate: candidate)
            draft.title = "Changed"
            draft.date = invalidDate

            XCTAssertFalse(draft.isRegistrationEligible)
            XCTAssertThrowsError(try draft.save(to: candidate, in: context))
            XCTAssertEqual(candidate.title, "Deadline")
            XCTAssertEqual(candidate.date, CalendarDate(year: 2030, month: 12, day: 1))
        }
    }

    func testInvalidTimeAndTimeZoneAreRejectedBeforeAnyCandidateMutation() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = makeCandidate(
            id: UUID(), title: "Meeting", date: CalendarDate(year: 2030, month: 11, day: 2),
            time: ClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Asia/Seoul"
        )
        context.insert(candidate)
        try context.save()
        for invalidTime in [ClockTime(hour: 24, minute: 0), ClockTime(hour: 10, minute: 60)] {
            var draft = CandidateDetailDraft(candidate: candidate)
            draft.title = "Changed"
            draft.time = invalidTime
            XCTAssertFalse(draft.isRegistrationEligible)
            XCTAssertThrowsError(try draft.save(to: candidate, in: context))
            XCTAssertEqual(candidate.title, "Meeting")
            XCTAssertEqual(candidate.time, ClockTime(hour: 14, minute: 30))
        }
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.timeZoneIdentifier = "Mars/Olympus"
        XCTAssertFalse(draft.isRegistrationEligible)
        XCTAssertThrowsError(try draft.save(to: candidate, in: context))
        XCTAssertEqual(candidate.timeZoneIdentifier, "Asia/Seoul")
    }

    func testChoosingValidTimeZoneOutsideSuggestedOptionsResolvesWarningAndRegisters() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = makeCandidate(
            id: UUID(), title: "New York meeting", date: CalendarDate(year: 2030, month: 11, day: 2),
            time: ClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Mars/Olympus",
            reviewReasons: [.unsupportedTimeZone]
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.timeZoneIdentifier = "America/New_York"
        XCTAssertTrue(draft.isRegistrationEligible)
        try draft.save(to: candidate, in: context)
        XCTAssertTrue(candidate.isRegistrationEligible)
        _ = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
            .register(candidateIDs: [candidate.id])
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 30))
        XCTAssertEqual(schedule.timeZoneIdentifier, "America/New_York")
    }

    func testUnsupportedSourceTimeZoneNeedsExplicitResolutionBeforeRegistration() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let parserDraft = try XCTUnwrap(DateTimeParser().parse(
            fragments: [RecognizedTextFragment(
                text: "Call 2030-11-02 14:00 TZ: XYZ",
                boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1), confidence: 0.99
            )],
            captureDate: Date(timeIntervalSince1970: 1_800_000_000),
            analysisDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(identifier: "America/New_York")!
        ).first)
        XCTAssertTrue(parserDraft.reviewReasons.contains(.unsupportedTimeZone))
        let candidate = makeCandidate(
            id: UUID(), title: "Call", date: parserDraft.date,
            time: parserDraft.time, timeZoneIdentifier: parserDraft.timeZoneIdentifier,
            reviewReasons: [.unsupportedTimeZone]
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertFalse(draft.isRegistrationEligible)
        try draft.save(to: candidate, in: context)
        XCTAssertEqual(candidate.reviewReasons, [.unsupportedTimeZone])
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try service.register(candidateIDs: [candidate.id]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        draft.confirmedReviewReasons.insert(.unsupportedTimeZone)
        try draft.save(to: candidate, in: context)
        XCTAssertTrue(candidate.isRegistrationEligible)
        _ = try service.register(candidateIDs: [candidate.id])
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(schedule.timeZoneIdentifier, "America/New_York")
    }

    func testUntimedCandidateDoesNotInventTimeAndRegistersAsAllDay() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let candidate = makeCandidate(
            id: UUID(), title: "Holiday", date: CalendarDate(year: 2030, month: 11, day: 2)
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        XCTAssertNil(draft.time)
        XCTAssertTrue(draft.isRegistrationEligible)
        try draft.save(to: candidate, in: context)
        XCTAssertNil(candidate.time)
        XCTAssertNil(candidate.timeZoneIdentifier)
        _ = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
            .register(candidateIDs: [candidate.id])
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2030, month: 11, day: 2))
        XCTAssertNil(schedule.time)
    }

    func testRecognizedDateTimeSurviveEntryCancelSaveReopenAndRegistration() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidateID = UUID()
        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.autosaveEnabled = false
            let candidate = makeCandidate(
                id: candidateID, title: "Conference", date: CalendarDate(year: 2030, month: 11, day: 2),
                time: ClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Asia/Seoul"
            )
            context.insert(candidate)
            try context.save()
            let state = CandidateSelectionState()
            state.synchronize(with: [candidate])
            var cancelledDraft = CandidateDetailDraft(candidate: candidate)
            cancelledDraft.date = CalendarDate(year: 2031, month: 1, day: 4)
            cancelledDraft.time = ClockTime(hour: 1, minute: 0)
            cancelledDraft.timeZoneIdentifier = "UTC"
            var reopenedDraft = CandidateDetailDraft(candidate: candidate)
            XCTAssertEqual(reopenedDraft.date, CalendarDate(year: 2030, month: 11, day: 2))
            XCTAssertEqual(reopenedDraft.time, ClockTime(hour: 14, minute: 30))
            XCTAssertEqual(reopenedDraft.timeZoneIdentifier, "Asia/Seoul")
            XCTAssertEqual(state.selectedCandidateIDs, [candidateID])
            try reopenedDraft.save(to: candidate, in: context)
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertTrue(stored.isRegistrationEligible)
        _ = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {})
            .register(candidateIDs: [candidateID])
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2030, month: 11, day: 2))
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 30))
        XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Seoul")
    }

    func testEditingDraftWithoutSavingPreservesCandidateAndSelection() {
        let candidate = makeCandidate(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000005")!,
            title: "Original",
            date: CalendarDate(year: 2026, month: 12, day: 3)
        )
        let state = CandidateSelectionState()
        state.synchronize(with: [candidate])
        var draft = CandidateDetailDraft(candidate: candidate)

        draft.title = "Changed"
        draft.date = nil

        XCTAssertEqual(candidate.title, "Original")
        XCTAssertEqual(candidate.date, CalendarDate(year: 2026, month: 12, day: 3))
        XCTAssertEqual(state.selectedCandidateIDs, [candidate.id])
    }

    func testMissingTimeRequiresConfirmationWhenCandidateRemainsWithoutTime() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let candidate = makeCandidate(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            title: "All-day event",
            date: CalendarDate(year: 2026, month: 12, day: 4),
            reviewReasons: [.missingTime]
        )
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)

        try draft.save(to: candidate, in: context)
        XCTAssertEqual(candidate.reviewReasons, [.missingTime])
        XCTAssertFalse(candidate.isRegistrationEligible)

        draft.confirmedReviewReasons.insert(.missingTime)
        try draft.save(to: candidate, in: context)
        XCTAssertEqual(candidate.reviewReasons, [])
        XCTAssertTrue(candidate.isRegistrationEligible)
    }

    func testDateConversionAlwaysUsesGregorianComponents() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let absoluteDate = try XCTUnwrap(
            gregorian.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))
        )
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = timeZone
        XCTAssertEqual(buddhist.component(.year, from: absoluteDate), 2569)

        let storedDate = CalendarDate.gregorianDate(from: absoluteDate, timeZone: timeZone)
        let roundTrip = try XCTUnwrap(storedDate.foundationDate(timeZone: timeZone))

        XCTAssertEqual(storedDate, CalendarDate(year: 2026, month: 10, day: 5))
        XCTAssertEqual(roundTrip, absoluteDate)
    }

    func testDetailFormSupportsLocalizedAccessibilityTextAndScrollableLayout() throws {
        let automation=try PresentationAutomationScope();defer {automation.restore()}
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let candidate = makeCandidate(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000007")!,
            title: "예약",
            date: CalendarDate(year: 2026, month: 10, day: 5),
            time: ClockTime(hour: 18, minute: 30),
            timeZoneIdentifier: "Asia/Seoul",
            reviewReasons: [.timeZoneInferred]
        )
        context.insert(candidate)
        try context.save()
        let rootView = NavigationStack {
            CandidateDetailView(candidate: candidate)
        }
        .modelContainer(container)
        .environment(\.locale, Locale.current)
        .environment(\.dynamicTypeSize, .accessibility5)
        let controller = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let scrollView = try XCTUnwrap(firstSubview(of: UIScrollView.self, in: controller.view))
        var labels = accessibilityLabels(in: controller.view)
        // Form is lazy at AX5. Reach the actual input before asserting its label.
        let top = -scrollView.adjustedContentInset.top
        let maximum = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        for step in 0..<16 {
            scrollView.setContentOffset(CGPoint(x: 0, y: min(top + CGFloat(step) * 120, maximum)), animated: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
            controller.view.layoutIfNeeded()
            labels += accessibilityLabels(in: controller.view)
            if labels.contains(where: { $0.contains(String(localized: "Title")) }) { break }
        }
        scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false)

        XCTAssertTrue(scrollView.isScrollEnabled)
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Title")) }, "Accessibility labels: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Register schedule")) }, "Accessibility labels: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Back")) }, "Accessibility labels: \(labels)")
        let screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Candidate detail – \(Locale.current.identifier) – accessibility5"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMissingTitleFormExposesPresetsAndDirectInputOnSmallScreen() throws {
        let automation=try PresentationAutomationScope();defer {automation.restore()}
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = makeCandidate(
            id: UUID(), title: "일정 확인 필요",
            date: CalendarDate(year: 2030, month: 11, day: 2),
            reviewReasons: [.missingTitle]
        )
        let context = ModelContext(container)
        context.insert(candidate)
        try context.save()
        let controller = UIHostingController(rootView: NavigationStack {
            CandidateDetailView(candidate: candidate)
                .navigationTitle(String(localized: "Candidate"))
                .navigationBarTitleDisplayMode(.inline)
        }.modelContainer(container))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let labels = accessibilityLabels(in: controller.view)
        for title in ["Gift voucher", "Application", "Ticket booking", "Event", "Enter your own title"] {
            let translated = String(localized: String.LocalizationValue(title))
            XCTAssertTrue(labels.contains { $0.contains(translated) }, "Missing accessible control: \(translated); \(labels)")
        }
        XCTAssertFalse(candidate.isRegistrationEligible)

        // Opt-in manual review hosts a disposable in-memory candidate; app data is untouched.
        if ProcessInfo.processInfo.environment["SNAPSCHEDULE_TITLE_UI_REVIEW"] == "1" {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 180))
        }
        let screenshot = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Missing title – \(Locale.current.identifier) – \(Int(window.bounds.width))pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeCandidate(
        id: UUID,
        title: String,
        date: CalendarDate? = nil,
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        reviewReasons: [CandidateReviewReason] = []
    ) -> ScheduleCandidate {
        ScheduleCandidate(
            id: id,
            sourceAssetIdentifier: "asset-\(id.uuidString)",
            sourceCandidateKey: "candidate-\(id.uuidString)",
            evidenceText: "Evidence text",
            title: title,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            reviewReasons: reviewReasons
        )
    }

    private func makeStoreLocation() throws -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "SnapSchedule.store"))
    }

    private func firstSubview<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func accessibilityLabels(in root: UIView) -> [String] {
        var labels: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, let label = object.accessibilityLabel {
                labels.append(label)
            }
            let count = object.accessibilityElementCount()
            if (1..<1_000).contains(count) {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        visit(element)
                    }
                }
            }
            if let view = object as? UIView {
                view.accessibilityElements?
                    .compactMap { $0 as? NSObject }
                    .forEach(visit)
                view.subviews.forEach(visit)
            }
        }

        visit(root)
        return labels
    }
}
