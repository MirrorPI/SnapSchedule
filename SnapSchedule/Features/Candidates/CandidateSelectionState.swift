import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CandidateSelectionState {
    private(set) var selectedCandidateIDs: Set<UUID> = []
    private(set) var detailCandidateID: UUID?
    private(set) var isDismissSelectionActive = false
    private(set) var dismissalCandidateIDs: Set<UUID> = []

    // Destructive selection is explicit and never inherits registration defaults.
    func beginDismissSelection() {
        dismissalCandidateIDs.removeAll()
        isDismissSelectionActive = true
    }

    func cancelDismissSelection() {
        dismissalCandidateIDs.removeAll()
        isDismissSelectionActive = false
    }

    func clearDismissSelection() { dismissalCandidateIDs.removeAll() }

    func toggleDismissSelection(_ candidate: ScheduleCandidate) {
        guard isDismissSelectionActive else { return }
        if dismissalCandidateIDs.contains(candidate.id) {
            dismissalCandidateIDs.remove(candidate.id)
        } else if candidate.reviewStatus == .pending, candidate.registeredScheduleID == nil {
            dismissalCandidateIDs.insert(candidate.id)
        }
    }

    @ObservationIgnored private var knownCandidateIDs: Set<UUID> = []

    var selectedCount: Int {
        selectedCandidateIDs.count
    }

    func synchronize(with candidates: [ScheduleCandidate]) {
        let currentIDs = Set(candidates.map(\.id))
        let newCandidates = candidates.filter { !knownCandidateIDs.contains($0.id) }

        selectedCandidateIDs.formIntersection(currentIDs)
        selectedCandidateIDs.formUnion(
            newCandidates.lazy.filter(\.isSelectedByDefault).map(\.id)
        )
        knownCandidateIDs.formUnion(currentIDs)
    }

    func toggle(_ candidateID: UUID) {
        if selectedCandidateIDs.contains(candidateID) {
            selectedCandidateIDs.remove(candidateID)
        } else {
            selectedCandidateIDs.insert(candidateID)
        }
    }

    func selectAll(_ candidates: [ScheduleCandidate]) {
        selectedCandidateIDs.formUnion(candidates.map(\.id))
        knownCandidateIDs.formUnion(candidates.map(\.id))
    }

    func deselectAll(_ candidates: [ScheduleCandidate]) {
        selectedCandidateIDs.subtract(candidates.map(\.id))
        knownCandidateIDs.formUnion(candidates.map(\.id))
    }

    func openDetails(_ candidateID: UUID) {
        detailCandidateID = candidateID
    }

    func dismiss(_ candidate: ScheduleCandidate, in context: ModelContext,
                 save: @escaping CandidateDismissalService.Save = { try $0.save() }) throws {
        try CandidateDismissalService(context: context, save: save).dismiss(candidateIDs: [candidate.id])
        selectedCandidateIDs.remove(candidate.id)
        if detailCandidateID == candidate.id {
            detailCandidateID = nil
        }
    }

    func dismissSelection(
        candidateIDs: Set<UUID>,
        in context: ModelContext,
        save: @escaping CandidateDismissalService.Save = { try $0.save() }
    ) throws {
        try CandidateDismissalService(context: context, save: save).dismiss(candidateIDs: candidateIDs)
        selectedCandidateIDs.removeAll()
        cancelDismissSelection()
        if let detailCandidateID, candidateIDs.contains(detailCandidateID) {
            self.detailCandidateID = nil
        }
    }
}

/// Shared visible-candidate scope for the list and Home. Undated legacy rows stay hidden.
enum CandidateListPresentation {
    static func pending(_ candidates: [ScheduleCandidate]) -> [ScheduleCandidate] {
        candidates.filter { $0.reviewStatus == .pending && ($0.date != nil || $0.hasEditedDateEntries) }
    }

    // Initial ordering stays unchanged. Edits cannot move surviving cards within an open gallery;
    // removals compact the existing order and newly analyzed candidates append in their sorted order.
    static func orderedPending(_ candidates: [ScheduleCandidate], scans: [ScreenshotScan], preserving order: [UUID]) -> [ScheduleCandidate] {
        let sorted = sortedPending(candidates, scans: scans)
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        let known = Set(order)
        return order.compactMap { byID[$0] } + sorted.filter { !known.contains($0.id) }
    }

    static func sortedPending(
        _ candidates: [ScheduleCandidate],
        scans: [ScreenshotScan]
    ) -> [ScheduleCandidate] {
        let discoveryDates = Dictionary(
            scans.map { ($0.assetIdentifier, $0.firstDiscoveredAt) },
            uniquingKeysWith: { min($0, $1) }
        )
        return pending(candidates).sorted { lhs, rhs in
            // pending() guarantees a date; compare saved calendar components, not time zones.
            guard let leftDate = lhs.date, let rightDate = rhs.date else { return false }
            if leftDate != rightDate {
                return (leftDate.year, leftDate.month, leftDate.day)
                    < (rightDate.year, rightDate.month, rightDate.day)
            }
            switch (discoveryDates[lhs.sourceAssetIdentifier], discoveryDates[rhs.sourceAssetIdentifier]) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            if lhs.sourceCandidateKey != rhs.sourceCandidateKey {
                return lhs.sourceCandidateKey < rhs.sourceCandidateKey
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct CandidateReviewSummary: Equatable {
    let pendingCount: Int
    let readyCount: Int
    var needsReviewCount: Int { pendingCount - readyCount }

    init(candidates: [ScheduleCandidate]) {
        let pending = CandidateListPresentation.pending(candidates)
        let photos = Dictionary(grouping: pending, by: \.sourceAssetIdentifier).values
        pendingCount = photos.count
        readyCount = photos.filter { $0.allSatisfy(\.isRegistrationEligible) }.count
    }
}
