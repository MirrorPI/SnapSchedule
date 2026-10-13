import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class ScanQueueTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case relatedChangeFailed
    }

    func testPreparingRepeatedDiscoveryCreatesOnePendingScanPerIdentifier() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context, now: { Date(timeIntervalSince1970: 100) })
        let assets = [asset("same"), asset("same"), asset("other")]

        try queue.prepare(for: .authorized(assets))
        try queue.prepare(for: .authorized(assets))

        let scans = try fetchScans(context)
        XCTAssertEqual(scans.map(\.assetIdentifier), ["other", "same"])
        XCTAssertEqual(scans.map(\.status), [.pending, .pending])
    }

    func testOnlyActiveExecutionOwnerCanClaimEachPendingScanOnce() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("one")]))

        let owner = try queue.beginExecution()
        XCTAssertThrowsError(try queue.beginExecution()) {
            XCTAssertEqual($0 as? ScanQueueError, .executionAlreadyActive)
        }

        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))
        XCTAssertEqual(claimed.assetIdentifier, "one")
        XCTAssertEqual(claimed.status, .analyzing)
        XCTAssertNil(try queue.claimNext(owner: owner))
        XCTAssertThrowsError(try queue.claimNext(owner: UUID())) {
            XCTAssertEqual($0 as? ScanQueueError, .invalidExecutionOwner)
        }
    }

    func testPreparingNextActivationRecoversAnalyzingAndRetryableButSkipsCompleted() throws {
        let context = try makeContext()
        context.insert(ScreenshotScan(assetIdentifier: "analyzing", status: .analyzing))
        context.insert(ScreenshotScan(assetIdentifier: "failed", status: .retryableFailure))
        context.insert(
            ScreenshotScan(
                assetIdentifier: "no-date",
                status: .completed,
                hasDateCandidates: false
            )
        )
        try context.save()

        let queue = ScanQueue(context: context)
        try queue.prepare(
            for: .authorized([asset("analyzing"), asset("failed"), asset("no-date")])
        )

        let owner = try queue.beginExecution()
        let claimedIDs = try [
            XCTUnwrap(queue.claimNext(owner: owner)).assetIdentifier,
            XCTUnwrap(queue.claimNext(owner: owner)).assetIdentifier,
        ]
        XCTAssertEqual(Set(claimedIDs), Set(["analyzing", "failed"]))
        XCTAssertNil(try queue.claimNext(owner: owner))
        XCTAssertEqual(try scan("no-date", in: context).status, .completed)
    }

    func testReopeningStoreRecoversOnlyInterruptedAnalyzingScan() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "SnapSchedule.store")

        do {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
            context.insert(ScreenshotScan(assetIdentifier: "interrupted", status: .analyzing))
            context.insert(ScreenshotScan(assetIdentifier: "completed", status: .completed, hasDateCandidates: false))
            try context.save()
        }

        let reopenedContext = ModelContext(try SnapScheduleModelContainer.make(url: storeURL))
        let queue = ScanQueue(context: reopenedContext)
        try queue.prepare(for: .authorized([asset("interrupted"), asset("completed")]))
        let owner = try queue.beginExecution()

        XCTAssertEqual(try queue.claimNext(owner: owner)?.assetIdentifier, "interrupted")
        XCTAssertNil(try queue.claimNext(owner: owner))
        XCTAssertEqual(try scan("completed", in: reopenedContext).status, .completed)
    }

    func testPermissionLossMarksOnlyUnfinishedScansInaccessibleAndVisibilityRecoveryRequeuesThem() throws {
        let context = try makeContext()
        context.insert(ScreenshotScan(assetIdentifier: "pending", status: .pending))
        context.insert(ScreenshotScan(assetIdentifier: "completed", status: .completed, hasDateCandidates: false))
        try context.save()
        let queue = ScanQueue(context: context)

        try queue.prepare(for: .unavailable(.denied))

        XCTAssertEqual(try scan("pending", in: context).status, .inaccessible)
        XCTAssertEqual(try scan("completed", in: context).status, .completed)

        try queue.prepare(for: .limited([asset("pending")]))

        XCTAssertEqual(try scan("pending", in: context).status, .pending)
        XCTAssertEqual(try scan("completed", in: context).status, .completed)
    }

    func testMissingAccessibleAssetBecomesInaccessibleUntilItReappears() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("visible")]))

        try queue.prepare(for: .limited([]))
        XCTAssertEqual(try scan("visible", in: context).status, .inaccessible)

        try queue.prepare(for: .authorized([asset("visible")]))
        XCTAssertEqual(try scan("visible", in: context).status, .pending)
    }

    func testRetryableFailureIsNotClaimedAgainUntilNextActivation() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))

        try queue.markRetryableFailure(
            claimed,
            owner: owner,
            code: "image-load",
            message: "temporarily unavailable"
        )

        XCTAssertNil(try queue.claimNext(owner: owner))
        try queue.endExecution(owner: owner)
        try queue.prepare(for: .authorized([asset("asset")]))
        let nextOwner = try queue.beginExecution()
        XCTAssertEqual(try queue.claimNext(owner: nextOwner)?.assetIdentifier, "asset")
    }

    func testRepeatedPreparationDuringExecutionDoesNotRequeueInFlightOrFailedScans() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("one"), asset("two")]))
        let owner = try queue.beginExecution()
        let failed = try XCTUnwrap(queue.claimNext(owner: owner))
        try queue.markRetryableFailure(failed, owner: owner, code: "temporary", message: nil)
        let inFlight = try XCTUnwrap(queue.claimNext(owner: owner))

        try queue.prepare(for: .authorized([asset("one"), asset("two")]))

        XCTAssertEqual(failed.status, .retryableFailure)
        XCTAssertEqual(inFlight.status, .analyzing)
        XCTAssertNil(try queue.claimNext(owner: owner))
    }

    func testExecutionOwnerCanExplicitlyRetryFailuresInTheSameActivation() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))
        try queue.markRetryableFailure(claimed, owner: owner, code: "temporary", message: nil)

        try queue.retryFailures(owner: owner)

        XCTAssertEqual(try queue.claimNext(owner: owner)?.assetIdentifier, "asset")
    }

    func testCompletionSavesRelatedCandidateInTheSameContext() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))

        try queue.complete(
            claimed,
            owner: owner,
            hasDateCandidates: true,
            analysisVersion: "vision-v1"
        ) { context in
            context.insert(
                ScheduleCandidate(
                    sourceAssetIdentifier: "asset",
                    sourceCandidateKey: "candidate-1",
                    title: "Appointment",
                    date: CalendarDate(year: 2026, month: 9, day: 20)
                )
            )
        }

        XCTAssertEqual(claimed.status, .completed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 1)
    }

    func testCompletionRollsBackRelatedChangesWhenTransactionFails() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))

        XCTAssertThrowsError(
            try queue.complete(
                claimed,
                owner: owner,
                hasDateCandidates: true,
                analysisVersion: "vision-v1"
            ) { context in
                context.insert(
                    ScheduleCandidate(
                        sourceAssetIdentifier: "asset",
                        sourceCandidateKey: "candidate-1",
                        title: "Appointment"
                    )
                )
                throw TestError.relatedChangeFailed
            }
        ) {
            XCTAssertEqual($0 as? TestError, .relatedChangeFailed)
        }

        XCTAssertEqual(claimed.status, .analyzing)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
    }

    func testCompletingNoDateResultPersistsAndNeverRequeues() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))
        let analyzedAt = Date(timeIntervalSince1970: 500)

        try queue.complete(
            claimed,
            owner: owner,
            hasDateCandidates: false,
            analysisVersion: "vision-v1",
            analyzedAt: analyzedAt
        )
        try queue.endExecution(owner: owner)
        try queue.prepare(for: .authorized([asset("asset")]))

        let persisted = try scan("asset", in: context)
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.hasDateCandidates, false)
        XCTAssertEqual(persisted.analysisVersion, "vision-v1")
        XCTAssertEqual(persisted.analyzedAt, analyzedAt)
        let nextOwner = try queue.beginExecution()
        XCTAssertNil(try queue.claimNext(owner: nextOwner))
    }

    func testNewIdentifierQueuesEvenWhenItsPhotoCreationDateIsOld() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        let oldDate = Date(timeIntervalSince1970: 1)

        try queue.prepare(
            for: .authorized([
                ScreenshotAssetMetadata(
                    assetIdentifier: "old-photo-new-id",
                    creationDate: oldDate,
                    pixelWidth: 100,
                    pixelHeight: 200
                )
            ])
        )

        XCTAssertEqual(try scan("old-photo-new-id", in: context).status, .pending)
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        return context
    }

    private func asset(_ identifier: String) -> ScreenshotAssetMetadata {
        ScreenshotAssetMetadata(
            assetIdentifier: identifier,
            creationDate: nil,
            pixelWidth: 100,
            pixelHeight: 200
        )
    }

    private func fetchScans(_ context: ModelContext) throws -> [ScreenshotScan] {
        try context.fetch(FetchDescriptor<ScreenshotScan>())
            .sorted { $0.assetIdentifier < $1.assetIdentifier }
    }

    private func scan(_ identifier: String, in context: ModelContext) throws -> ScreenshotScan {
        try XCTUnwrap(fetchScans(context).first { $0.assetIdentifier == identifier })
    }
}
