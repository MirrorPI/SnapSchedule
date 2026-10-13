import Foundation
import SwiftData

enum LocalDataStoreError: Error, Equatable {
    case duplicateAssetIdentifier(String)
    case duplicateCandidateKey(String, String)
    case duplicateSourceCandidateID(UUID)
    case missingTimeZone
    case timeZoneWithoutTime
}

@MainActor
final class LocalDataStore {
    let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func add(_ scan: ScreenshotScan) throws {
        let assetIdentifier = scan.assetIdentifier
        let descriptor = FetchDescriptor<ScreenshotScan>(
            predicate: #Predicate { $0.assetIdentifier == assetIdentifier }
        )
        guard try context.fetchCount(descriptor) == 0 else {
            throw LocalDataStoreError.duplicateAssetIdentifier(assetIdentifier)
        }
        try insertAndSave(scan)
    }

    func add(_ candidate: ScheduleCandidate) throws {
        try validateTimeZone(time: candidate.time, timeZoneIdentifier: candidate.timeZoneIdentifier)
        let assetIdentifier = candidate.sourceAssetIdentifier
        let candidateKey = candidate.sourceCandidateKey
        let descriptor = FetchDescriptor<ScheduleCandidate>(
            predicate: #Predicate {
                $0.sourceAssetIdentifier == assetIdentifier && $0.sourceCandidateKey == candidateKey
            }
        )
        guard try context.fetchCount(descriptor) == 0 else {
            throw LocalDataStoreError.duplicateCandidateKey(assetIdentifier, candidateKey)
        }
        try insertAndSave(candidate)
    }

    func add(_ schedule: Schedule) throws {
        try validateTimeZone(time: schedule.time, timeZoneIdentifier: schedule.timeZoneIdentifier)
        let sourceCandidateID = schedule.sourceCandidateID
        let descriptor = FetchDescriptor<Schedule>(
            predicate: #Predicate { $0.sourceCandidateID == sourceCandidateID }
        )
        guard !(try context.fetch(descriptor)).contains(where: {
            $0.date == schedule.date && $0.time == schedule.time
                && $0.timeZoneIdentifier == schedule.timeZoneIdentifier
        }) else {
            throw LocalDataStoreError.duplicateSourceCandidateID(sourceCandidateID)
        }
        try insertAndSave(schedule)
    }

    private func insertAndSave(_ model: some PersistentModel) throws {
        context.insert(model)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func validateTimeZone(time: ClockTime?, timeZoneIdentifier: String?) throws {
        if time != nil && (timeZoneIdentifier?.isEmpty != false) {
            throw LocalDataStoreError.missingTimeZone
        }
        if time == nil && timeZoneIdentifier != nil {
            throw LocalDataStoreError.timeZoneWithoutTime
        }
    }
}
