import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import SnapSchedule

@MainActor
final class CandidateSelectionStateTests: XCTestCase {
    func testSummaryAndBadgeCountPhotosWhileKeepingLegacyCandidatesSeparate() {
        let first = ScheduleCandidate(sourceAssetIdentifier: "old-shared-photo", sourceCandidateKey: "one", title: "First",
            date: CalendarDate(year: 2026, month: 10, day: 18))
        let second = ScheduleCandidate(sourceAssetIdentifier: "old-shared-photo", sourceCandidateKey: "two", title: "Second",
            date: CalendarDate(year: 2026, month: 10, day: 20), reviewReasons: [.ambiguousDate])
        let other = ScheduleCandidate(sourceAssetIdentifier: "other-photo", sourceCandidateKey: "one", title: "Other",
            date: CalendarDate(year: 2026, month: 10, day: 22))
        let candidates = [first, second, other]
        XCTAssertEqual(CandidateListPresentation.pending(candidates).count, 3, "Existing records must remain separate")
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).pendingCount, 2)
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).readyCount, 1)
        XCTAssertEqual(CandidateReviewPresentation(candidates: candidates).badge(scanStatus: ScanStatus()), "2")
        first.reviewStatus = .registered
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).pendingCount, 2)
        second.reviewStatus = .dismissed
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).pendingCount, 1)
        XCTAssertEqual(other.reviewStatus, .pending)
        XCTAssertEqual(first.reviewStatus, .registered)
    }
    func testDismissSelectionIsExplicitIndependentAndRejectsRegisteredCandidates() {
        let first = batchCandidate(1), needsReview = batchCandidate(2, reviewReasons: [.relativeDate])
        let registered = batchCandidate(3), linked = batchCandidate(4), incoming = batchCandidate(5)
        registered.reviewStatus = .registered; linked.registeredScheduleID = UUID()
        let state = CandidateSelectionState(); state.synchronize(with: [first, needsReview])
        state.toggleDismissSelection(first)
        XCTAssertTrue(state.dismissalCandidateIDs.isEmpty, "Normal mode cannot accumulate ignore targets")
        state.beginDismissSelection()
        XCTAssertTrue(state.dismissalCandidateIDs.isEmpty, "Registration defaults cannot select destructive targets")
        state.toggleDismissSelection(first); state.toggleDismissSelection(needsReview)
        state.toggleDismissSelection(registered); state.toggleDismissSelection(linked)
        XCTAssertEqual(state.dismissalCandidateIDs, [first.id, needsReview.id])
        state.synchronize(with: [first, needsReview, incoming])
        XCTAssertEqual(state.dismissalCandidateIDs, [first.id, needsReview.id], "New candidates require explicit selection")
        XCTAssertEqual(state.selectedCandidateIDs, [first.id, incoming.id], "Registration selection keeps its existing contract")
        state.clearDismissSelection(); XCTAssertTrue(state.dismissalCandidateIDs.isEmpty)
        XCTAssertTrue(state.isDismissSelectionActive)
        state.toggleDismissSelection(first); state.cancelDismissSelection()
        XCTAssertTrue(state.dismissalCandidateIDs.isEmpty); XCTAssertFalse(state.isDismissSelectionActive)
        XCTAssertEqual(state.selectedCandidateIDs, [first.id, incoming.id])
        state.beginDismissSelection(); XCTAssertTrue(state.dismissalCandidateIDs.isEmpty)
    }

    func testInitialSynchronizationSelectsOnlyClearTitledCandidatesWithValidDates() {
        let clearDateTime = candidate(
            id: "10000000-0000-0000-0000-000000000001",
            key: "clear-date-time",
            title: "Team sync",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: ClockTime(hour: 14, minute: 0),
            timeZoneIdentifier: "Asia/Seoul"
        )
        let clearDateOnly = candidate(
            id: "10000000-0000-0000-0000-000000000002",
            key: "clear-date-only",
            title: "Submission deadline",
            date: CalendarDate(year: 2026, month: 10, day: 4)
        )
        let inferredYear = candidate(
            id: "10000000-0000-0000-0000-000000000003",
            key: "inferred-year",
            title: "Appointment",
            date: CalendarDate(year: 2026, month: 10, day: 5),
            reviewReasons: [.yearInferredFromCaptureDate]
        )
        let timeOnly = candidate(
            id: "10000000-0000-0000-0000-000000000004",
            key: "time-only",
            title: "Dinner",
            time: ClockTime(hour: 18, minute: 30),
            reviewReasons: [.missingDate]
        )
        let invalidDate = candidate(
            id: "10000000-0000-0000-0000-000000000005",
            key: "invalid-date",
            title: "Impossible date",
            date: CalendarDate(year: 2026, month: 2, day: 30)
        )
        let untitled = candidate(
            id: "10000000-0000-0000-0000-000000000006",
            key: "untitled",
            title: "   ",
            date: CalendarDate(year: 2026, month: 10, day: 6)
        )
        let inferredTimeZone = candidate(
            id: "10000000-0000-0000-0000-000000000007",
            key: "inferred-time-zone",
            title: "Call",
            date: CalendarDate(year: 2026, month: 10, day: 7),
            time: ClockTime(hour: 9, minute: 0),
            timeZoneIdentifier: "Asia/Seoul",
            reviewReasons: [.timeZoneInferred]
        )
        let placeholderTitle = candidate(
            id: "10000000-0000-0000-0000-000000000008",
            key: "missing-title",
            title: "일정 확인 필요",
            date: CalendarDate(year: 2026, month: 10, day: 8),
            reviewReasons: [.missingTitle]
        )
        let state = CandidateSelectionState()

        state.synchronize(with: [
            clearDateTime,
            clearDateOnly,
            inferredYear,
            timeOnly,
            invalidDate,
            untitled,
            inferredTimeZone,
            placeholderTitle,
        ])

        XCTAssertEqual(state.selectedCandidateIDs, [clearDateTime.id, clearDateOnly.id, inferredTimeZone.id])
        XCTAssertFalse(clearDateTime.requiresReview)
        XCTAssertTrue(inferredYear.requiresReview)
        XCTAssertTrue(timeOnly.requiresReview)
        XCTAssertTrue(invalidDate.requiresReview)
        XCTAssertTrue(untitled.requiresReview)
        XCTAssertFalse(inferredTimeZone.requiresReview)
        XCTAssertTrue(placeholderTitle.requiresReview)
    }

    func testSynchronizationPreservesExistingChoicesAndAppliesDefaultsOnlyToNewCandidates() {
        let first = candidate(
            id: "20000000-0000-0000-0000-000000000001",
            key: "first",
            title: "First",
            date: CalendarDate(year: 2026, month: 11, day: 1)
        )
        let newlyAnalyzed = candidate(
            id: "20000000-0000-0000-0000-000000000002",
            key: "new",
            title: "New",
            date: CalendarDate(year: 2026, month: 11, day: 2)
        )
        let needsReview = candidate(
            id: "20000000-0000-0000-0000-000000000003",
            key: "needs-review",
            title: "Needs review",
            date: CalendarDate(year: 2026, month: 11, day: 3),
            reviewReasons: [.relativeDate]
        )
        let state = CandidateSelectionState()

        state.synchronize(with: [first])
        state.toggle(first.id)
        state.synchronize(with: [first, newlyAnalyzed, needsReview])

        XCTAssertEqual(state.selectedCandidateIDs, [newlyAnalyzed.id])

        state.selectAll([first, newlyAnalyzed, needsReview])
        XCTAssertEqual(state.selectedCandidateIDs, [first.id, newlyAnalyzed.id, needsReview.id])

        state.toggle(first.id)
        XCTAssertEqual(state.selectedCandidateIDs, [newlyAnalyzed.id, needsReview.id])

        state.deselectAll([first, newlyAnalyzed, needsReview])
        XCTAssertTrue(state.selectedCandidateIDs.isEmpty)
    }

    func testOpenDetailsPublishesCandidateIDWithoutChangingSelection() {
        let candidate = candidate(
            id: "30000000-0000-0000-0000-000000000001",
            key: "details",
            title: "Details",
            date: CalendarDate(year: 2026, month: 12, day: 1)
        )
        let state = CandidateSelectionState()
        state.synchronize(with: [candidate])

        state.openDetails(candidate.id)

        XCTAssertEqual(state.detailCandidateID, candidate.id)
        XCTAssertEqual(state.selectedCandidateIDs, [candidate.id])
    }

    func testDismissPersistsAndRemovesCandidateFromSessionSelection() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidateID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

        do {
            let container = try SnapScheduleModelContainer.make(url: storeURL)
            let store = LocalDataStore(container: container)
            let stored = candidate(
                id: candidateID.uuidString,
                key: "dismissed",
                title: "Dismiss me",
                date: CalendarDate(year: 2026, month: 12, day: 2)
            )
            try store.add(stored)
            let state = CandidateSelectionState()
            state.synchronize(with: [stored])

            try state.dismiss(stored, in: store.context)

            XCTAssertEqual(stored.reviewStatus, .dismissed)
            XCTAssertFalse(state.selectedCandidateIDs.contains(candidateID))
        }

        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(reopened)
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        XCTAssertEqual(stored.reviewStatus, .dismissed)
    }

    func testIndividualIgnoreRejectsRegisteredCandidateWithoutChangingSelection() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        let stored = candidate(
            id: "40000000-0000-0000-0000-000000000002",
            key: "registered", title: "Registered",
            date: CalendarDate(year: 2026, month: 10, day: 3)
        )
        context.insert(stored)
        try context.save()
        let state = CandidateSelectionState()
        state.synchronize(with: [stored])
        stored.reviewStatus = .registered
        stored.registeredScheduleID = UUID()
        try context.save()

        XCTAssertThrowsError(try state.dismiss(stored, in: context))
        XCTAssertEqual(stored.reviewStatus, .registered)
        XCTAssertNotNil(stored.registeredScheduleID)
        XCTAssertEqual(state.selectedCandidateIDs, [stored.id])
    }

    func testGalleryExposesSeparatePhotoDetailsAndIgnoreAccessibilityElements() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let stored = candidate(
            id: "50000000-0000-0000-0000-000000000001",
            key: "accessible-row",
            title: "Appointment",
            date: CalendarDate(year: 2026, month: 10, day: 5),
            reviewReasons: [.yearInferredFromCaptureDate]
        )
        context.insert(stored)
        try context.save()
        let state = CandidateSelectionState()
        let rootView = NavigationStack {
            CandidateListView(selectionState: state, onOpenCandidate: { _ in })
        }
        .modelContainer(container)
        let controller = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        var labels = accessibilityLabels(in: controller.view)

        XCTAssertFalse(labels.contains(String(localized: "Select \("Appointment")")))
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Original screenshot")) })
        XCTAssertTrue(labels.contains(String(localized: "Ignore actions for \("Appointment")")))
        XCTAssertTrue(
            labels.contains {
                $0.contains("Appointment")
                    && $0.contains("2026")
                    && $0.contains(String(localized: "Review needed"))
                    && $0.contains(String(localized: "Details"))
            }
        )

        let newlyAnalyzed = candidate(
            id: "50000000-0000-0000-0000-000000000002",
            key: "live-insertion",
            title: "Submission deadline",
            date: CalendarDate(year: 2026, month: 10, day: 6)
        )
        context.insert(newlyAnalyzed)
        try context.save()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        labels = accessibilityLabels(in: controller.view)

        XCTAssertEqual(state.selectedCandidateIDs, [newlyAnalyzed.id])
        // SwiftUI localizes the separator between a LabeledContent label and value.
        for (title, count) in [
            (String(localized: "Pending candidates"), 2),
            (String(localized: "Review needed"), 1),
            (String(localized: "Ready to register"), 1),
        ] {
            XCTAssertTrue(
                labels.contains { $0.contains(title) && $0.contains(count.formatted()) },
                "Missing summary \(title): \(count) in \(labels)"
            )
        }
    }

    func testGalleryHidesBatchActionsEvenWhenLegacySelectionChanges() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        context.insert(
            candidate(
                id: "50000000-0000-0000-0000-000000000003",
                key: "ready-to-register",
                title: "Ready",
                date: CalendarDate(year: 2026, month: 10, day: 7)
            )
        )
        try context.save()
        let state = CandidateSelectionState()
        let rootView = NavigationStack {
            CandidateListView(selectionState: state, onOpenCandidate: { _ in })
        }
        .modelContainer(container)
        let controller = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        // Summary and row status can push actions below a small screen's viewport.
        scrollToBottom(in: controller.view)
        let labels = accessibilityLabels(in: controller.view)

        XCTAssertFalse(labels.contains(String(localized: "Register \(1) candidates")))
        XCTAssertFalse(labels.contains(String(localized: "Ignore \(1) Candidates")))
        let selectedImage = UIGraphicsImageRenderer(bounds: controller.view.bounds).image {
            _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let selectedAttachment = XCTAttachment(image: selectedImage)
        selectedAttachment.name = "Task32 selected UI"
        selectedAttachment.lifetime = .keepAlways
        add(selectedAttachment)

        state.deselectAll(try context.fetch(FetchDescriptor<ScheduleCandidate>()))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(state.selectedCount, 0)
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Task32 deselected UI"
        attachment.lifetime = .keepAlways
        add(attachment)
        // This helper enumerates offscreen/recycled UIKit accessibility nodes too.
        // Assert the updated action rather than absence of a cached deleted cell.
        scrollToBottom(in: controller.view)
        let deselectedLabels = accessibilityLabels(in: controller.view)
        XCTAssertFalse(deselectedLabels.contains(String(localized: "Register \(0) candidates")))

    }

    func testBatchIgnorePersistsOnlyConfirmedIDsAndClearsSelectionAfterNewArrival() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let first = batchCandidate(1)
        let second = batchCandidate(2, reviewReasons: [.missingTitle])
        let unselected = batchCandidate(3)
        let scan = ScreenshotScan(assetIdentifier: first.sourceAssetIdentifier, status: .completed)
        [first, second, unselected].forEach(context.insert)
        context.insert(scan)
        try context.save()
        let state = CandidateSelectionState()
        state.synchronize(with: [first, second, unselected])
        state.deselectAll([unselected])
        state.toggle(second.id)
        state.openDetails(first.id)
        let confirmedIDs = state.selectedCandidateIDs
        let incoming = batchCandidate(4)
        context.insert(incoming)
        try context.save()
        state.synchronize(with: [first, second, unselected, incoming])
        XCTAssertEqual(state.selectedCandidateIDs, [first.id, second.id, incoming.id])

        try state.dismissSelection(candidateIDs: confirmedIDs, in: context)

        XCTAssertTrue(state.selectedCandidateIDs.isEmpty)
        XCTAssertNil(state.detailCandidateID)
        XCTAssertEqual(first.reviewStatus, .dismissed)
        XCTAssertEqual(second.reviewStatus, .dismissed)
        XCTAssertEqual(unselected.reviewStatus, .pending)
        XCTAssertEqual(incoming.reviewStatus, .pending)
        state.synchronize(with: [unselected, incoming])
        XCTAssertTrue(state.selectedCandidateIDs.isEmpty)
        let reopened = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let stored = try reopened.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(Set(stored.filter { $0.reviewStatus == .dismissed }.map(\.id)), confirmedIDs)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<ScreenshotScan>()).first?.status, .completed)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testBatchIgnoreSaveFailureRestoresEveryCandidateAndSelectionThenRetrySucceeds() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        context.autosaveEnabled = false
        let first = batchCandidate(1)
        let second = batchCandidate(2)
        [first, second].forEach(context.insert)
        try context.save()
        let state = CandidateSelectionState()
        state.synchronize(with: [first, second])
        state.openDetails(second.id)
        enum Failure: Error { case save }

        XCTAssertThrowsError(try state.dismissSelection(
            candidateIDs: state.selectedCandidateIDs, in: context,
            save: { changedContext in
                // Fail at the save boundary after every model has been mutated.
                XCTAssertTrue(try changedContext.fetch(FetchDescriptor<ScheduleCandidate>())
                    .allSatisfy { $0.reviewStatus == .dismissed })
                throw Failure.save
            }
        )) { XCTAssertEqual($0 as? CandidateDismissalError, .saveFailed) }
        XCTAssertEqual(first.reviewStatus, .pending)
        XCTAssertEqual(second.reviewStatus, .pending)
        XCTAssertEqual(state.selectedCandidateIDs, [first.id, second.id])
        XCTAssertEqual(state.detailCandidateID, second.id)
        XCTAssertFalse(context.hasChanges)
        let reopened = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        XCTAssertTrue(try reopened.fetch(FetchDescriptor<ScheduleCandidate>())
            .allSatisfy { $0.reviewStatus == .pending })

        try state.dismissSelection(candidateIDs: state.selectedCandidateIDs, in: context)
        XCTAssertEqual(first.reviewStatus, .dismissed)
        XCTAssertEqual(second.reviewStatus, .dismissed)
        XCTAssertTrue(state.selectedCandidateIDs.isEmpty)
    }

    func testBatchIgnoreRejectsStaleIDsBeforeChangingAnyPendingCandidate() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        let valid = batchCandidate(1)
        let registered = batchCandidate(2)
        registered.reviewStatus = .registered
        registered.registeredScheduleID = UUID()
        let ignored = batchCandidate(3)
        ignored.reviewStatus = .dismissed
        let linked = batchCandidate(4)
        linked.registeredScheduleID = UUID()
        let withSchedule = batchCandidate(5)
        let schedule = Schedule(sourceCandidateID: withSchedule.id, title: "Saved",
            date: CalendarDate(year: 2026, month: 10, day: 3), sourceAssetIdentifier: "asset")
        let candidates = [valid, registered, ignored, linked, withSchedule]
        candidates.forEach(context.insert)
        context.insert(schedule)
        try context.save()
        let state = CandidateSelectionState()
        state.selectAll(candidates)
        let missing = UUID()
        state.toggle(missing)
        let selectedIDs = state.selectedCandidateIDs

        XCTAssertThrowsError(try state.dismissSelection(candidateIDs: selectedIDs, in: context)) {
            XCTAssertEqual($0 as? CandidateDismissalError, .selectionChanged)
        }
        XCTAssertEqual(valid.reviewStatus, .pending)
        XCTAssertEqual(registered.reviewStatus, .registered)
        XCTAssertEqual(ignored.reviewStatus, .dismissed)
        XCTAssertEqual(linked.reviewStatus, .pending)
        XCTAssertEqual(withSchedule.reviewStatus, .pending)
        XCTAssertEqual(state.selectedCandidateIDs, selectedIDs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
        XCTAssertFalse(context.hasChanges)
        // Each stale type must independently block the batch.
        for stale in [registered.id, ignored.id, linked.id, withSchedule.id, missing] {
            XCTAssertThrowsError(try state.dismissSelection(candidateIDs: [valid.id, stale], in: context))
            XCTAssertEqual(valid.reviewStatus, .pending)
        }
    }

    func testEmptyBatchIgnorePreservesCandidatesAndSelection() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let stored = batchCandidate(1)
        context.insert(stored)
        try context.save()
        let state = CandidateSelectionState()
        state.selectAll([stored])

        XCTAssertThrowsError(try state.dismissSelection(candidateIDs: [], in: context)) {
            XCTAssertEqual($0 as? CandidateDismissalError, .noSelection)
        }
        XCTAssertEqual(stored.reviewStatus, .pending)
        XCTAssertEqual(state.selectedCandidateIDs, [stored.id])
    }

    func testIndividualIgnoreKeepsOtherSelectionsAndDetail() throws {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        let first = batchCandidate(1)
        let second = batchCandidate(2)
        [first, second].forEach(context.insert)
        try context.save()
        let state = CandidateSelectionState()
        state.selectAll([first, second])
        state.openDetails(second.id)

        try state.dismiss(first, in: context)

        XCTAssertEqual(first.reviewStatus, .dismissed)
        XCTAssertEqual(second.reviewStatus, .pending)
        XCTAssertEqual(state.selectedCandidateIDs, [second.id])
        XCTAssertEqual(state.detailCandidateID, second.id)
    }

    func testPresentationSortsByDateThenDiscoveryIgnoringTitleAssetNameAndTime() {
        let earlierDate = batchCandidate(1)
        earlierDate.date = CalendarDate(year: 2026, month: 9, day: 30)
        let earlierScan = batchCandidate(3)
        earlierScan.title = "Z title"
        earlierScan.time = ClockTime(hour: 23, minute: 0)
        earlierScan.timeZoneIdentifier = "Asia/Seoul"
        let laterScan = batchCandidate(2)
        laterScan.title = "A title"
        let scans = [
            ScreenshotScan(assetIdentifier: earlierScan.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 1)),
            ScreenshotScan(assetIdentifier: laterScan.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 2))
        ]
        let input = [laterScan, earlierScan, earlierDate]
        let expected = [earlierDate.id, earlierScan.id, laterScan.id]
        XCTAssertEqual(CandidateListPresentation.sortedPending(input, scans: scans).map(\.id), expected)
        XCTAssertEqual(CandidateListPresentation.sortedPending(input.reversed(), scans: scans.reversed()).map(\.id), expected)
    }

    func testPresentationTiesAndMissingScansHaveDeterministicFallback() {
        let linked = batchCandidate(9)
        let firstKey = batchCandidate(1)
        let secondKey = batchCandidate(2)
        let sameKey = ScheduleCandidate(
            id: UUID(uuidString: "33000000-0000-0000-0000-000000000001")!,
            sourceAssetIdentifier: "different-asset", sourceCandidateKey: firstKey.sourceCandidateKey,
            title: "Same key", date: firstKey.date
        )
        let scan = ScreenshotScan(assetIdentifier: linked.sourceAssetIdentifier, firstDiscoveredAt: .distantFuture)
        let input = [secondKey, sameKey, firstKey, linked]
        XCTAssertEqual(CandidateListPresentation.sortedPending(input, scans: [scan]).map(\.id),
                       [linked.id, firstKey.id, sameKey.id, secondKey.id])
        let tiedScans = input.map {
            ScreenshotScan(assetIdentifier: $0.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(CandidateListPresentation.sortedPending(input.reversed(), scans: tiedScans).map(\.id),
                       [firstKey.id, sameKey.id, secondKey.id, linked.id])
    }

    func testSummaryUsesRegistrationValidityAndExcludesHiddenCandidates() {
        let ready = batchCandidate(1)
        let review = batchCandidate(2, reviewReasons: [.relativeDate])
        let invalidTimeZone = batchCandidate(3)
        invalidTimeZone.time = ClockTime(hour: 10, minute: 0)
        invalidTimeZone.timeZoneIdentifier = "Invalid/Zone"
        let invalidTime = batchCandidate(4)
        invalidTime.time = ClockTime(hour: 25, minute: 0)
        invalidTime.timeZoneIdentifier = "Asia/Seoul"
        let missingDate = batchCandidate(5)
        missingDate.date = nil
        let ignored = batchCandidate(6)
        ignored.reviewStatus = .dismissed
        let registered = batchCandidate(7)
        registered.reviewStatus = .registered
        let input = [ready, review, invalidTimeZone, invalidTime, missingDate, ignored, registered]
        let summary = CandidateReviewSummary(candidates: input)
        XCTAssertEqual(summary.pendingCount, 4)
        XCTAssertEqual(summary.readyCount, 1)
        XCTAssertEqual(summary.needsReviewCount, 3)
        XCTAssertEqual(CandidateListPresentation.sortedPending(input, scans: []).count, summary.pendingCount)
        XCTAssertTrue(CandidateText.accessibilityLabel(invalidTimeZone).contains(String(localized: "Review needed")))
        XCTAssertTrue(CandidateText.accessibilityLabel(ready).contains(String(localized: "Ready to register")))
        review.reviewReasons = []
        XCTAssertEqual(CandidateReviewSummary(candidates: input).readyCount, 2)
    }

    func testEditingIgnoringAndNewArrivalPreserveSelectionAndDetailIdentity() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let first = batchCandidate(1)
        let edited = batchCandidate(2, reviewReasons: [.relativeDate])
        [first, edited].forEach { context.insert($0) }
        try context.save()
        let selection = CandidateSelectionState()
        selection.synchronize(with: CandidateListPresentation.sortedPending([first, edited], scans: []))
        selection.toggle(first.id)
        selection.toggle(edited.id)
        selection.openDetails(edited.id)
        edited.date = CalendarDate(year: 2026, month: 9, day: 1)
        edited.reviewReasons = []
        let incoming = batchCandidate(3)
        context.insert(incoming)
        try context.save()
        let input = [first, edited, incoming]
        selection.synchronize(with: CandidateListPresentation.sortedPending(input, scans: []))
        XCTAssertEqual(selection.selectedCandidateIDs, [edited.id, incoming.id])
        XCTAssertEqual(selection.detailCandidateID, edited.id)
        XCTAssertEqual(CandidateListPresentation.sortedPending(input, scans: []).first?.id, edited.id)
        try selection.dismiss(incoming, in: context)
        XCTAssertEqual(selection.selectedCandidateIDs, [edited.id])
        XCTAssertEqual(selection.detailCandidateID, edited.id)
        XCTAssertEqual(CandidateReviewSummary(candidates: input).pendingCount, 2)
        XCTAssertEqual(CandidateReviewSummary(candidates: input).readyCount, 2)
    }

    func testPresentationSurvivesPersistentStoreReopen() throws {
        let location = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let expected = try autoreleasepool {
            let container = try SnapScheduleModelContainer.make(url: location.storeURL)
            let context = ModelContext(container)
            let first = batchCandidate(2)
            let second = batchCandidate(1, reviewReasons: [.relativeDate])
            let hidden = batchCandidate(3)
            hidden.reviewStatus = .dismissed
            [first, second, hidden].forEach { context.insert($0) }
            context.insert(ScreenshotScan(assetIdentifier: first.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 1)))
            context.insert(ScreenshotScan(assetIdentifier: second.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 2)))
            try context.save()
            return [first.id, second.id]
        }
        let reopened = try SnapScheduleModelContainer.make(url: location.storeURL)
        let context = ModelContext(reopened)
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        let scans = try context.fetch(FetchDescriptor<ScreenshotScan>())
        let sorted = CandidateListPresentation.sortedPending(candidates, scans: scans)
        XCTAssertEqual(sorted.map(\.id), expected)
        let summary = CandidateReviewSummary(candidates: candidates)
        XCTAssertEqual(summary.pendingCount, 2)
        XCTAssertEqual(summary.needsReviewCount, 1)
        XCTAssertEqual(summary.readyCount, 1)
        let freshSession = CandidateSelectionState()
        freshSession.synchronize(with: sorted)
        XCTAssertEqual(freshSession.selectedCandidateIDs, [expected[0]])
    }

    func testTask33MultiCandidateScreensAndLiveSummary() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = ModelContext(container)
        let first = batchCandidate(2, reviewReasons: [.relativeDate])
        first.title = "Earlier discovery"
        let second = batchCandidate(1)
        second.title = "Later discovery"
        let third = batchCandidate(3)
        third.title = "Later date"
        third.date = CalendarDate(year: 2026, month: 10, day: 4)
        let input = [second, third, first]
        input.forEach { context.insert($0) }
        context.insert(ScreenshotScan(assetIdentifier: first.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 1)))
        context.insert(ScreenshotScan(assetIdentifier: second.sourceAssetIdentifier, firstDiscoveredAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        let selection = CandidateSelectionState()
        let root = NavigationStack {
            CandidateListView(selectionState: selection, onOpenCandidate: { _ in })
        }.modelContainer(container)
        .dynamicTypeSize(.large)
        let controller = UIHostingController(rootView: root)
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
        func layout() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
        func snapshot(_ name: String, view: UIView) {
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
                _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Task33-\(name)-\(Bundle.main.preferredLocalizations.first ?? "unknown")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        layout()
        let initialLabels = accessibilityLabels(in: controller.view)
        snapshot("list-before", view: controller.view)
        first.reviewReasons = []
        try context.save()
        layout()
        let readyLabels = accessibilityLabels(in: controller.view)
        XCTAssertEqual(selection.selectedCandidateIDs, [second.id, third.id])
        snapshot("list-ready", view: controller.view)
        scrollToBottom(in: controller.view)
        snapshot("list-bottom", view: controller.view)
        let analysis = UIHostingController(rootView: ScanStatusView(
            status: ScanStatus(state: .completed, photoAccess: .authorized, pendingCandidateCount: 99),
            candidateSummary: CandidateReviewSummary(candidates: input)
        ).padding())
        window.rootViewController = analysis
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        analysis.view.layoutIfNeeded()
        let homeLabels = accessibilityLabels(in: analysis.view)
        snapshot("home-summary", view: analysis.view)

        #if !targetEnvironment(simulator)
        // Some physical-device unit-test hosts render SwiftUI but expose no AX tree.
        // Keep screenshots for manual verification; never report that as an AX pass.
        try XCTSkipIf(initialLabels.isEmpty && readyLabels.isEmpty && homeLabels.isEmpty,
                      "Hosted accessibility tree unavailable on this device. Four Task33 screenshots require manual review.")
        #endif
        for (title, count) in [(String(localized: "Pending candidates"), 3),
                               (String(localized: "Review needed"), 1),
                               (String(localized: "Ready to register"), 2)] {
            XCTAssertTrue(initialLabels.contains { $0.hasPrefix(title) && $0.contains(count.formatted()) }, "\(title): \(initialLabels)")
        }
        // The first visible detail action must belong to the earliest discovered source.
        let details = initialLabels.filter { $0.contains(String(localized: "Details")) && $0.contains("discovery") && !$0.contains(String(localized: "Original screenshot")) }
        XCTAssertTrue(details.first?.hasPrefix(first.title) == true, "\(details)")
        XCTAssertTrue(readyLabels.contains { $0.hasPrefix(String(localized: "Ready to register")) && $0.contains("3") })
        XCTAssertTrue(readyLabels.contains { $0.hasPrefix(first.title) && $0.contains(String(localized: "Ready to register")) })
        XCTAssertTrue(homeLabels.contains { $0.contains(String(localized: "Pending candidates (all batches)")) && $0.contains("3") })
        XCTAssertFalse(homeLabels.contains { $0.contains("99") })
    }

    private func batchCandidate(_ number: Int, reviewReasons: [CandidateReviewReason] = []) -> ScheduleCandidate {
        candidate(id: String(format: "32000000-0000-0000-0000-%012d", number),
            key: "batch-\(number)", title: "Candidate \(number)",
            date: CalendarDate(year: 2026, month: 10, day: 3), reviewReasons: reviewReasons)
    }

    private func candidate(
        id: String,
        key: String,
        title: String,
        date: CalendarDate? = nil,
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        reviewReasons: [CandidateReviewReason] = []
    ) -> ScheduleCandidate {
        ScheduleCandidate(
            id: UUID(uuidString: id)!,
            sourceAssetIdentifier: "asset-\(key)",
            sourceCandidateKey: key,
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

    private func scrollToBottom(in root: UIView) {
        if let scroll = root as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            scroll.setContentOffset(CGPoint(
                x: 0,
                y: max(-scroll.adjustedContentInset.top,
                       scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            ), animated: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            scroll.layoutIfNeeded()
            return
        }
        root.subviews.forEach { scrollToBottom(in: $0) }
    }

    private func accessibilityLabels(in root: UIView) -> [String] {
        var labels: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement, let label = object.accessibilityLabel {
                labels.append(label)
            }
            // SwiftUI on newer OS versions exposes virtual accessibility containers.
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
