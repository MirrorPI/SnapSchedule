import Foundation
import SwiftData

enum ScanQueueError: Error, Equatable {
    case executionAlreadyActive
    case invalidExecutionOwner
    case scanIsNotAnalyzing(String)
}

@MainActor
final class ScanQueue {
    typealias RelatedChanges = (ModelContext) throws -> Void

    private let context: ModelContext
    private let now: () -> Date
    private var activeExecutionOwner: UUID?

    init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    func prepare(for discovery: ScreenshotDiscoveryResult) throws {
        let scans = try context.fetch(FetchDescriptor<ScreenshotScan>())

        switch discovery {
        case .unavailable:
            for scan in scans where scan.status != .completed {
                scan.status = .inaccessible
            }

        case let .authorized(assets), let .limited(assets):
            let visibleIdentifiers = Set(assets.map(\.assetIdentifier))

            for scan in scans where scan.status != .completed {
                guard visibleIdentifiers.contains(scan.assetIdentifier) else {
                    scan.status = .inaccessible
                    continue
                }

                switch scan.status {
                case .analyzing where activeExecutionOwner != nil:
                    break
                case .retryableFailure where activeExecutionOwner != nil:
                    break
                case .pending, .analyzing, .retryableFailure, .inaccessible:
                    scan.status = .pending
                case .completed:
                    break
                }
            }

            let knownIdentifiers = Set(scans.map(\.assetIdentifier))
            for identifier in visibleIdentifiers.subtracting(knownIdentifiers) {
                context.insert(
                    ScreenshotScan(
                        assetIdentifier: identifier,
                        firstDiscoveredAt: now(),
                        status: .pending
                    )
                )
            }
        }

        try saveOrRollback()
    }

    func beginExecution() throws -> UUID {
        guard activeExecutionOwner == nil else {
            throw ScanQueueError.executionAlreadyActive
        }

        let owner = UUID()
        activeExecutionOwner = owner
        return owner
    }

    func claimNext(owner: UUID) throws -> ScreenshotScan? {
        try validate(owner: owner)

        let pending = try context.fetch(FetchDescriptor<ScreenshotScan>())
            .filter { $0.status == .pending }
            .sorted {
                if $0.firstDiscoveredAt != $1.firstDiscoveredAt {
                    return $0.firstDiscoveredAt < $1.firstDiscoveredAt
                }
                return $0.assetIdentifier < $1.assetIdentifier
            }

        guard let scan = pending.first else { return nil }
        scan.status = .analyzing
        try saveOrRollback()
        return scan
    }

    func complete(
        _ scan: ScreenshotScan,
        owner: UUID,
        hasDateCandidates: Bool,
        analysisVersion: String?,
        analyzedAt: Date = .now,
        relatedChanges: RelatedChanges = { _ in }
    ) throws {
        try validateAnalyzing(scan, owner: owner)
        do {
            try relatedChanges(context)
            scan.status = .completed
            scan.analyzedAt = analyzedAt
            scan.analysisVersion = analysisVersion
            scan.failureCode = nil
            scan.failureMessage = nil
            scan.hasDateCandidates = hasDateCandidates
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func markRetryableFailure(
        _ scan: ScreenshotScan,
        owner: UUID,
        code: String,
        message: String?
    ) throws {
        try validateAnalyzing(scan, owner: owner)
        scan.status = .retryableFailure
        scan.failureCode = code
        scan.failureMessage = message
        try saveOrRollback()
    }

    func markInaccessible(_ scan: ScreenshotScan, owner: UUID) throws {
        try validateAnalyzing(scan, owner: owner)
        scan.status = .inaccessible
        try saveOrRollback()
    }

    func retryFailures(owner: UUID) throws {
        try validate(owner: owner)
        let scans = try context.fetch(FetchDescriptor<ScreenshotScan>())
        for scan in scans where scan.status == .retryableFailure {
            scan.status = .pending
        }
        try saveOrRollback()
    }

    func endExecution(owner: UUID) throws {
        try validate(owner: owner)
        activeExecutionOwner = nil
    }

    private func validate(owner: UUID) throws {
        guard activeExecutionOwner == owner else {
            throw ScanQueueError.invalidExecutionOwner
        }
    }

    private func validateAnalyzing(_ scan: ScreenshotScan, owner: UUID) throws {
        try validate(owner: owner)
        guard scan.status == .analyzing else {
            throw ScanQueueError.scanIsNotAnalyzing(scan.assetIdentifier)
        }
    }

    private func saveOrRollback() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
