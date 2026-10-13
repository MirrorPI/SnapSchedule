import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class PersistenceTests: XCTestCase {
    func testLocalStoreAllowsDifferentDatesFromOneSourceButRejectsRepeatedDateTimeZone() throws {
        let store = LocalDataStore(container: try SnapScheduleModelContainer.makeInMemory())
        let source = UUID()
        for day in [18, 20] {
            try store.add(Schedule(sourceCandidateID: source, title: "Meeting",
                date: CalendarDate(year: 2026, month: 10, day: day),
                time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul", sourceAssetIdentifier: "photo"))
        }
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Schedule>()), 2)
        XCTAssertThrowsError(try store.add(Schedule(sourceCandidateID: source, title: "Repeat",
            date: CalendarDate(year: 2026, month: 10, day: 18), time: ClockTime(hour: 14, minute: 0),
            timeZoneIdentifier: "Asia/Seoul", sourceAssetIdentifier: "photo")))
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Schedule>()), 2)
    }
    func testPreBatchStoreOpensWithoutChangingExistingIDsLinksOrStates() throws {
        let fixture = URL(fileURLWithPath: "/private/tmp/SnapScheduleTask421LegacyBatch")
        guard FileManager.default.fileExists(atPath: fixture.appending(path: "legacy.store").path) else {
            throw XCTSkip("Generate the pre-batch fixture using the old build first")
        }
        let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: copy.appending(path: "legacy.store")))
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(candidates.count, 3)
        let candidate = try XCTUnwrap(candidates.first { $0.sourceAssetIdentifier == "legacy-photo" })
        let expectedID = UUID(uuidString: "42010000-0000-0000-0000-000000000001")!
        let scheduleID = UUID(uuidString: "42010000-0000-0000-0000-000000000002")!
        XCTAssertEqual(candidate.id, expectedID)
        XCTAssertEqual(candidate.title, "User edited title")
        XCTAssertEqual(candidate.sourceCandidateKey, "legacy-key")
        XCTAssertEqual(candidate.evidenceText, "Original evidence")
        XCTAssertEqual(candidate.reviewStatus, .registered)
        XCTAssertEqual(candidate.registeredScheduleIDs, [scheduleID])
        XCTAssertEqual(candidate.dateEntries.count, 1)
        XCTAssertTrue(candidate.recognizedDateOptions.isEmpty)
        XCTAssertEqual(candidates.first { $0.title == "Keep pending" }?.reviewStatus, .pending)
        XCTAssertEqual(candidates.first { $0.title == "Keep dismissed" }?.reviewStatus, .dismissed)
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.id, scheduleID)
        XCTAssertEqual(schedule.sourceCandidateID, expectedID)
        XCTAssertEqual(schedule.title, "Saved edit")
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(schedule.timeZoneIdentifier, "US/Pacific")
        XCTAssertEqual(schedule.sourceAssetIdentifier, "legacy-photo")
        XCTAssertEqual(schedule.createdAt, Date(timeIntervalSince1970: 1234567890))
        XCTAssertEqual(schedule.updatedAt, Date(timeIntervalSince1970: 1234567900))
        XCTAssertEqual(schedule.calendarEventIdentifier, "existing-event")
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
        XCTAssertTrue(schedule.notifyDayBefore)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScreenshotScan>()).first?.analysisVersion, "vision3-parser2-filter1")
        let extra = Schedule(sourceCandidateID: expectedID, title: "Independent date",
            date: CalendarDate(year: 2026, month: 10, day: 22), sourceAssetIdentifier: "legacy-photo")
        context.insert(extra); try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 2, "The migrated schema permits multiple schedules per source")
    }
    func testWritePreBatchSchemaFixture() throws {
        guard ProcessInfo.processInfo.environment["SNAPSCHEDULE_WRITE_LEGACY_BATCH_FIXTURE"] == "1" else {
            throw XCTSkip("Only run against the pre-batch model, before schema edits")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/SnapScheduleTask421LegacyBatch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidateID = UUID(uuidString: "42010000-0000-0000-0000-000000000001")!
        let scheduleID = UUID(uuidString: "42010000-0000-0000-0000-000000000002")!
        try autoreleasepool {
            let container = try SnapScheduleModelContainer.make(url: directory.appending(path: "legacy.store"))
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(ScreenshotScan(assetIdentifier: "legacy-photo", status: .completed,
                analysisVersion: "vision3-parser2-filter1", hasDateCandidates: true))
            context.insert(ScheduleCandidate(id: candidateID, sourceAssetIdentifier: "legacy-photo",
                sourceCandidateKey: "legacy-key", evidenceText: "Original evidence", title: "User edited title",
                date: CalendarDate(year: 2026, month: 10, day: 18), time: ClockTime(hour: 14, minute: 0),
                timeZoneIdentifier: "US/Pacific", notifyDayBefore: true, calendarExportRequested: true,
                reviewStatus: .registered, registeredScheduleID: scheduleID))
            context.insert(Schedule(id: scheduleID, sourceCandidateID: candidateID, title: "Saved edit",
                date: CalendarDate(year: 2026, month: 10, day: 18), time: ClockTime(hour: 14, minute: 0),
                timeZoneIdentifier: "US/Pacific", sourceAssetIdentifier: "legacy-photo",
                createdAt: Date(timeIntervalSince1970: 1234567890), updatedAt: Date(timeIntervalSince1970: 1234567900),
                notifyDayBefore: true, calendarExportStatus: .succeeded, calendarEventIdentifier: "existing-event"))
            context.insert(ScheduleCandidate(sourceAssetIdentifier: "old-multiple", sourceCandidateKey: "one",
                title: "Keep pending", date: CalendarDate(year: 2026, month: 10, day: 20)))
            context.insert(ScheduleCandidate(sourceAssetIdentifier: "old-multiple", sourceCandidateKey: "two",
                title: "Keep dismissed", date: CalendarDate(year: 2026, month: 10, day: 21), reviewStatus: .dismissed))
            try context.save()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "legacy.store").path))
    }
    func testModelsPersistAfterReopeningOnDiskStore() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        let discoveredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let analyzedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let candidateID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let scheduleID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

        do {
            let container = try SnapScheduleModelContainer.make(url: storeURL)
            let store = LocalDataStore(container: container)
            try store.add(
                ScreenshotScan(
                    assetIdentifier: "asset-1",
                    firstDiscoveredAt: discoveredAt,
                    status: .completed,
                    analyzedAt: analyzedAt,
                    analysisVersion: "vision-v1",
                    hasDateCandidates: true
                )
            )
            try store.add(
                ScheduleCandidate(
                    id: candidateID,
                    sourceAssetIdentifier: "asset-1",
                    sourceCandidateKey: "candidate-1",
                    evidenceText: "9/20 14:30 appointment",
                    evidenceLocation: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1),
                    title: "Appointment",
                    date: CalendarDate(year: 2026, month: 9, day: 20),
                    time: ClockTime(hour: 14, minute: 30),
                    timeZoneIdentifier: "Asia/Seoul",
                    reviewReason: .ambiguousDate,
                    notifyDayBefore: true,
                    notifySameDay: false,
                    calendarExportRequested: true,
                    reviewStatus: .registered,
                    registeredScheduleID: scheduleID
                )
            )
            try store.add(
                Schedule(
                    id: scheduleID,
                    sourceCandidateID: candidateID,
                    title: "Appointment",
                    date: CalendarDate(year: 2026, month: 9, day: 20),
                    time: ClockTime(hour: 14, minute: 30),
                    timeZoneIdentifier: "Asia/Seoul",
                    sourceAssetIdentifier: "asset-1",
                    createdAt: analyzedAt,
                    updatedAt: analyzedAt,
                    notifyDayBefore: true,
                    notifySameDay: false,
                    calendarExportStatus: .pending
                )
            )
        }

        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(reopened)
        let scans = try context.fetch(FetchDescriptor<ScreenshotScan>())
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        let schedules = try context.fetch(FetchDescriptor<Schedule>())

        XCTAssertEqual(scans.count, 1)
        XCTAssertEqual(scans[0].assetIdentifier, "asset-1")
        XCTAssertEqual(scans[0].status, .completed)
        XCTAssertEqual(scans[0].analysisVersion, "vision-v1")
        XCTAssertEqual(scans[0].hasDateCandidates, true)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].evidenceLocation, NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1))
        XCTAssertEqual(candidates[0].registeredScheduleID, scheduleID)
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules[0].sourceCandidateID, candidateID)
        XCTAssertEqual(schedules[0].calendarExportStatus, .pending)
    }

    func testScanCandidateAndScheduleStatesRemainIndependent() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let store = LocalDataStore(container: container)
        let scheduleID = UUID()

        try store.add(ScreenshotScan(assetIdentifier: "asset", status: .completed, hasDateCandidates: true))
        try store.add(ScheduleCandidate(sourceAssetIdentifier: "asset", sourceCandidateKey: "one", title: "One"))
        try store.add(
            ScheduleCandidate(
                sourceAssetIdentifier: "asset",
                sourceCandidateKey: "two",
                title: "Two",
                reviewStatus: .dismissed
            )
        )
        let registeredCandidate = ScheduleCandidate(
            sourceAssetIdentifier: "asset",
            sourceCandidateKey: "three",
            title: "Three",
            reviewStatus: .registered,
            registeredScheduleID: scheduleID
        )
        try store.add(registeredCandidate)
        try store.add(
            Schedule(
                id: scheduleID,
                sourceCandidateID: registeredCandidate.id,
                title: "Three",
                date: CalendarDate(year: 2026, month: 9, day: 21),
                sourceAssetIdentifier: "asset"
            )
        )

        store.context.delete(try XCTUnwrap(try store.context.fetch(FetchDescriptor<ScreenshotScan>()).first))
        try store.context.save()

        let candidates = try store.context.fetch(FetchDescriptor<ScheduleCandidate>())
        let schedules = try store.context.fetch(FetchDescriptor<Schedule>())
        XCTAssertEqual(candidates.map(\.reviewStatus), [.pending, .dismissed, .registered])
        XCTAssertEqual(schedules.count, 1, "Deleting or losing the source scan must not delete a registered schedule")
        XCTAssertEqual(schedules[0].sourceAssetIdentifier, "asset")
    }

    func testMissingDateDateOnlyAndZonedDateTimeRoundTripWithoutSentinels() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try SnapScheduleModelContainer.make(url: storeURL)
            let store = LocalDataStore(container: container)
            try store.add(
                ScheduleCandidate(
                    sourceAssetIdentifier: "asset",
                    sourceCandidateKey: "undated",
                    title: "Unknown"
                )
            )
            try store.add(
                Schedule(
                    sourceCandidateID: UUID(),
                    title: "All day",
                    date: CalendarDate(year: 2026, month: 12, day: 31),
                    sourceAssetIdentifier: "asset"
                )
            )
            try store.add(
                Schedule(
                    sourceCandidateID: UUID(),
                    title: "Call",
                    date: CalendarDate(year: 2027, month: 1, day: 1),
                    time: ClockTime(hour: 9, minute: 5),
                    timeZoneIdentifier: "America/New_York",
                    sourceAssetIdentifier: "asset"
                )
            )
        }

        let reopened = try SnapScheduleModelContainer.make(url: storeURL)
        let context = ModelContext(reopened)
        let candidate = try XCTUnwrap(try context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        let dateOnly = try XCTUnwrap(schedules.first { $0.title == "All day" })
        let zoned = try XCTUnwrap(schedules.first { $0.title == "Call" })

        XCTAssertNil(candidate.date)
        XCTAssertNil(candidate.time)
        XCTAssertNil(dateOnly.time, "A date-only schedule must not be represented as midnight")
        XCTAssertNil(dateOnly.timeZoneIdentifier)
        XCTAssertEqual(zoned.date, CalendarDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(zoned.time, ClockTime(hour: 9, minute: 5))
        XCTAssertEqual(zoned.timeZoneIdentifier, "America/New_York")
    }

    func testCandidateDefaultsToCurrentTimeZoneAndScheduleRequiresExplicitTimeZone() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let store = LocalDataStore(container: container)
        let timedCandidate = ScheduleCandidate(
            sourceAssetIdentifier: "asset",
            sourceCandidateKey: "timed",
            title: "Candidate",
            time: ClockTime(hour: 9, minute: 0)
        )
        let dateOnlyWithTimeZone = Schedule(
            sourceCandidateID: UUID(),
            title: "Schedule",
            date: CalendarDate(year: 2026, month: 9, day: 20),
            timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: "asset"
        )
        let timedScheduleWithoutTimeZone = Schedule(
            sourceCandidateID: UUID(),
            title: "Timed schedule",
            date: CalendarDate(year: 2026, month: 9, day: 20),
            time: ClockTime(hour: 9, minute: 0),
            sourceAssetIdentifier: "asset"
        )

        try store.add(timedCandidate)
        XCTAssertEqual(timedCandidate.timeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertThrowsError(try store.add(dateOnlyWithTimeZone)) {
            XCTAssertEqual($0 as? LocalDataStoreError, .timeZoneWithoutTime)
        }
        XCTAssertThrowsError(try store.add(timedScheduleWithoutTimeZone)) {
            XCTAssertEqual($0 as? LocalDataStoreError, .missingTimeZone)
        }
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 1)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testDuplicateKeysFailWithoutChangingExistingData() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let store = LocalDataStore(container: container)
        let originalCandidateID = UUID()

        try store.add(ScreenshotScan(assetIdentifier: "asset", status: .completed))
        try store.add(
            ScheduleCandidate(
                id: originalCandidateID,
                sourceAssetIdentifier: "asset",
                sourceCandidateKey: "same-key",
                title: "Original"
            )
        )
        try store.add(
            Schedule(
                sourceCandidateID: originalCandidateID,
                title: "Original schedule",
                date: CalendarDate(year: 2026, month: 9, day: 20),
                sourceAssetIdentifier: "asset"
            )
        )

        XCTAssertThrowsError(try store.add(ScreenshotScan(assetIdentifier: "asset", status: .inaccessible))) {
            XCTAssertEqual($0 as? LocalDataStoreError, .duplicateAssetIdentifier("asset"))
        }
        XCTAssertThrowsError(
            try store.add(
                ScheduleCandidate(
                    sourceAssetIdentifier: "asset",
                    sourceCandidateKey: "same-key",
                    title: "Replacement"
                )
            )
        ) {
            XCTAssertEqual($0 as? LocalDataStoreError, .duplicateCandidateKey("asset", "same-key"))
        }
        XCTAssertThrowsError(
            try store.add(
                Schedule(
                    sourceCandidateID: originalCandidateID,
                    title: "Replacement schedule",
                    date: CalendarDate(year: 2026, month: 9, day: 20),
                    sourceAssetIdentifier: "asset"
                )
            )
        ) {
            XCTAssertEqual($0 as? LocalDataStoreError, .duplicateSourceCandidateID(originalCandidateID))
        }

        let scans = try store.context.fetch(FetchDescriptor<ScreenshotScan>())
        let candidates = try store.context.fetch(FetchDescriptor<ScheduleCandidate>())
        let schedules = try store.context.fetch(FetchDescriptor<Schedule>())
        XCTAssertEqual(scans.count, 1)
        XCTAssertEqual(scans[0].status, .completed)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].title, "Original")
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules[0].title, "Original schedule")
    }

    func testSaveFailureRollsBackPendingInsertAndPreservesStoredData() throws {
        let (directory, storeURL) = try makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let writableContainer = try SnapScheduleModelContainer.make(url: storeURL)
            let writableStore = LocalDataStore(container: writableContainer)
            try writableStore.add(ScreenshotScan(assetIdentifier: "existing", status: .completed))
        }

        let schema = Schema([ScreenshotScan.self, ScheduleCandidate.self, Schedule.self])
        let readOnlyConfiguration = ModelConfiguration(
            "SnapSchedule",
            schema: schema,
            url: storeURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let readOnlyContainer = try ModelContainer(for: schema, configurations: [readOnlyConfiguration])
        let readOnlyStore = LocalDataStore(container: readOnlyContainer)

        XCTAssertThrowsError(
            try readOnlyStore.add(ScreenshotScan(assetIdentifier: "pending", status: .pending))
        )

        let scans = try readOnlyStore.context.fetch(FetchDescriptor<ScreenshotScan>())
        XCTAssertEqual(scans.count, 1)
        XCTAssertEqual(scans[0].assetIdentifier, "existing")
        XCTAssertEqual(scans[0].status, .completed)
    }

    func testContainerConfigurationExplicitlyDisablesCloudKit() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let configuration = try XCTUnwrap(container.configurations.first)

        XCTAssertTrue(
            configuration.debugDescription.contains(
                "cloudKitDatabase: CloudKitDatabase(_automatic: false, _none: true"
            )
        )
    }

    private func makeStoreLocation() throws -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "SnapSchedule.store"))
    }
}
