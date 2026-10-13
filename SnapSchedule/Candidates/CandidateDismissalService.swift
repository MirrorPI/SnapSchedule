import Foundation
import SwiftData

enum CandidateDismissalError: Error, Equatable {
    case noSelection
    case selectionChanged
    case saveFailed
}

@MainActor
final class CandidateDismissalService {
    typealias Save = (ModelContext) throws -> Void

    private let context: ModelContext
    private let save: Save

    init(context: ModelContext, save: @escaping Save = { try $0.save() }) {
        self.context = context
        self.save = save
    }

    func dismiss(candidateIDs: Set<UUID>) throws {
        guard !candidateIDs.isEmpty else { throw CandidateDismissalError.noSelection }

        let candidates: [ScheduleCandidate]
        let latestCandidates: [ScheduleCandidate]
        let registeredIDs: Set<UUID>
        let readContext = ModelContext(context.container)
        readContext.autosaveEnabled = false
        do {
            candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
                .filter { candidateIDs.contains($0.id) }
            latestCandidates = try readContext.fetch(FetchDescriptor<ScheduleCandidate>())
                .filter { candidateIDs.contains($0.id) }
            registeredIDs = Set(try readContext.fetch(FetchDescriptor<Schedule>()).map(\.sourceCandidateID))
        } catch {
            throw CandidateDismissalError.saveFailed
        }

        guard candidates.count == candidateIDs.count,
              latestCandidates.count == candidateIDs.count,
              latestCandidates.allSatisfy({ $0.reviewStatus == .pending && $0.registeredScheduleIDs.isEmpty }),
              candidates.allSatisfy({
                  $0.reviewStatus == .pending && $0.registeredScheduleIDs.isEmpty
                      && !registeredIDs.contains($0.id)
              }) else {
            throw CandidateDismissalError.selectionChanged
        }

        do {
            candidates.forEach { $0.reviewStatus = .dismissed }
            try save(context)
        } catch {
            // Restore observable model values too, including on newer SwiftData runtimes.
            candidates.forEach { $0.reviewStatus = .pending }
            context.rollback()
            throw CandidateDismissalError.saveFailed
        }
    }
}
