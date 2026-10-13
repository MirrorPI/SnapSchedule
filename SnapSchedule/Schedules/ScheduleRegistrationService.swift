import Foundation
import SwiftData

enum ScheduleRegistrationIssueReason: Equatable {
    case unavailable
    case notPending
    case needsReview
    case alreadyRegistered
}

struct ScheduleRegistrationIssue: Equatable {
    let candidateID: UUID
    let reason: ScheduleRegistrationIssueReason
}

enum ScheduleRegistrationError: Error, Equatable {
    case noSelection
    case validationFailed([ScheduleRegistrationIssue])
    case saveFailed
}

struct ScheduleRegistrationResult: Equatable {
    let scheduleIDs: [UUID]
}

@MainActor
final class ScheduleRegistrationService {
    typealias Save = (ModelContext) throws -> Void
    typealias WidgetSnapshotRefresh = () throws -> Void

    private let context: ModelContext
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let save: Save
    private let widgetSnapshotRefresh: WidgetSnapshotRefresh

    init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current },
        save: @escaping Save = { try $0.save() },
        widgetSnapshotRefresh: WidgetSnapshotRefresh? = nil
    ) {
        self.context = context
        self.now = now
        self.timeZone = timeZone
        self.save = save
        self.widgetSnapshotRefresh = widgetSnapshotRefresh ?? {
            let schedules = try context.fetch(FetchDescriptor<Schedule>())
            _ = try WidgetSnapshotStore().write(schedules: schedules)
        }
    }

    func register(candidateIDs: Set<UUID>) throws -> ScheduleRegistrationResult {
        guard !candidateIDs.isEmpty else {
            throw ScheduleRegistrationError.noSelection
        }

        let storedCandidates: [ScheduleCandidate]
        let latestCandidates: [ScheduleCandidate]
        let registeredCandidateIDs: Set<UUID>
        let readContext = ModelContext(context.container)
        readContext.autosaveEnabled = false
        do {
            storedCandidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
            latestCandidates = try readContext.fetch(FetchDescriptor<ScheduleCandidate>())
            registeredCandidateIDs = Set(
                try readContext.fetch(FetchDescriptor<Schedule>()).map(\.sourceCandidateID)
            )
        } catch {
            throw ScheduleRegistrationError.saveFailed
        }

        let candidatesByID = Dictionary(uniqueKeysWithValues: storedCandidates.map { ($0.id, $0) })
        let latestByID = Dictionary(uniqueKeysWithValues: latestCandidates.map { ($0.id, $0) })
        let sortedIDs = candidateIDs.sorted { $0.uuidString < $1.uuidString }
        var issues: [ScheduleRegistrationIssue] = []
        var selectedCandidates: [(write: ScheduleCandidate, value: ScheduleCandidate)] = []
        let fallbackZone = timeZone().identifier

        for candidateID in sortedIDs {
            guard let candidate = candidatesByID[candidateID], let latest = latestByID[candidateID] else {
                issues.append(ScheduleRegistrationIssue(candidateID: candidateID, reason: .unavailable))
                continue
            }
            if !candidate.registeredScheduleIDs.isEmpty || !latest.registeredScheduleIDs.isEmpty || registeredCandidateIDs.contains(candidateID) {
                issues.append(ScheduleRegistrationIssue(candidateID: candidateID, reason: .alreadyRegistered))
            } else if candidate.reviewStatus != .pending || latest.reviewStatus != .pending {
                issues.append(ScheduleRegistrationIssue(candidateID: candidateID, reason: .notPending))
            } else if !candidate.isRegistrationEligible || !latest.isRegistrationEligible
                || latest.dateEntries.hasDuplicateDates(fallbackZone: fallbackZone) {
                issues.append(ScheduleRegistrationIssue(candidateID: candidateID, reason: .needsReview))
            } else {
                selectedCandidates.append((write: candidate, value: latest))
            }
        }

        guard issues.isEmpty else {
            throw ScheduleRegistrationError.validationFailed(issues)
        }

        let registeredAt = now()
        let batches = selectedCandidates.map { selected in
            let candidate = selected.value
            return (candidate: selected.write, schedules: candidate.dateEntries.map { entry in
                Schedule(
                    sourceCandidateID: candidate.id,
                    title: candidate.title,
                    date: entry.date!,
                    time: entry.time,
                    timeZoneIdentifier: entry.timeZoneIdentifier ?? fallbackZone,
                    sourceAssetIdentifier: candidate.sourceAssetIdentifier,
                    createdAt: registeredAt,
                    updatedAt: registeredAt,
                    notifyDayBefore: candidate.notifyDayBefore,
                    notifySameDay: candidate.notifySameDay,
                    calendarExportStatus: candidate.calendarExportRequested ? .pending : .notRequested
                )
            })
        }
        let schedules = batches.flatMap(\.schedules)
        do {
            for batch in batches {
                batch.schedules.forEach(context.insert)
                batch.candidate.reviewStatus = .registered
                batch.candidate.registeredScheduleIDs = batch.schedules.map(\.id)
            }
            // One save is the commit boundary for every schedule and every source candidate.
            try save(context)
            try? widgetSnapshotRefresh()
            return ScheduleRegistrationResult(scheduleIDs: schedules.map(\.id))
        } catch {
            context.rollback()
            for candidate in selectedCandidates.map(\.write) {
                candidate.reviewStatus = .pending
                candidate.registeredScheduleIDs = []
            }
            throw ScheduleRegistrationError.saveFailed
        }
    }

    /// A fetch on an existing context can return a cached pending model. Check the
    /// committed record before an editor writes or a source is registered again.
    static func requirePending(candidateID: UUID, in context: ModelContext) throws {
        let readContext = ModelContext(context.container)
        readContext.autosaveEnabled = false
        let candidate: ScheduleCandidate?
        let hasSchedules: Bool
        do {
            candidate = try readContext.fetch(FetchDescriptor<ScheduleCandidate>(
                predicate: #Predicate { $0.id == candidateID })).first
            hasSchedules = try readContext.fetchCount(FetchDescriptor<Schedule>(
                predicate: #Predicate { $0.sourceCandidateID == candidateID })) > 0
        } catch { throw ScheduleRegistrationError.saveFailed }
        let reason: ScheduleRegistrationIssueReason?
        if let candidate {
            if !candidate.registeredScheduleIDs.isEmpty || hasSchedules { reason = .alreadyRegistered }
            else if candidate.reviewStatus != .pending { reason = .notPending }
            else { reason = nil }
        } else { reason = .unavailable }
        if let reason {
            throw ScheduleRegistrationError.validationFailed([ScheduleRegistrationIssue(candidateID: candidateID, reason: reason)])
        }
    }
}
