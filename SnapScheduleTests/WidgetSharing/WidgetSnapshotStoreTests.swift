import Foundation
import XCTest
@testable import SnapSchedule

@MainActor
final class WidgetSnapshotStoreTests: XCTestCase {
    private enum TestError: Error { case writeFailed }

    func testWriteRoundTripsOnlyUpcomingWidgetFieldsInStableOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedAt = date(2026, 10, 1, 12, 0)
        let store = WidgetSnapshotStore(
            containerURL: { directory },
            now: { generatedAt },
            deviceTimeZone: { TimeZone(secondsFromGMT: 0)! }
        )
        let later = schedule(
            id: id(2),
            title: "Dinner",
            date: CalendarDate(year: 2026, month: 10, day: 3),
            time: ClockTime(hour: 18, minute: 30),
            timeZoneIdentifier: "Asia/Seoul"
        )
        let sooner = schedule(
            id: id(1),
            title: "All day",
            date: CalendarDate(year: 2026, month: 10, day: 2),
            timeZoneIdentifier: "UTC"
        )
        let past = schedule(
            id: id(3),
            title: "Past",
            date: CalendarDate(year: 2026, month: 9, day: 30),
            timeZoneIdentifier: "UTC"
        )

        let written = try store.write(schedules: [later, past, sooner])

        XCTAssertEqual(written.formatVersion, 1)
        XCTAssertEqual(written.generatedAt, generatedAt)
        XCTAssertEqual(written.schedules.map(\.id), [sooner.id, later.id])
        XCTAssertEqual(
            written.schedules,
            [
                WidgetScheduleSnapshot(
                    id: sooner.id,
                    title: "All day",
                    date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
                    time: nil,
                    timeZoneIdentifier: "UTC"
                ),
                WidgetScheduleSnapshot(
                    id: later.id,
                    title: "Dinner",
                    date: WidgetCalendarDate(year: 2026, month: 10, day: 3),
                    time: WidgetClockTime(hour: 18, minute: 30),
                    timeZoneIdentifier: "Asia/Seoul"
                ),
            ]
        )
        XCTAssertEqual(store.read(), .success(written))

        let data = try Data(contentsOf: directory.appending(path: WidgetSnapshotStore.fileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(object["schedules"] as? [[String: Any]])
        XCTAssertEqual(Set(items[0].keys), ["id", "title", "date", "timeZoneIdentifier"])
        XCTAssertNil(data.range(of: Data("sourceAssetIdentifier".utf8)))
        XCTAssertNil(data.range(of: Data("sourceCandidateID".utf8)))
    }

    func testRewriteReplacesRegistrationUpdateDeleteAndEmptyState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var currentDate = date(2026, 10, 1, 12, 0)
        let store = WidgetSnapshotStore(
            containerURL: { directory },
            now: { currentDate },
            deviceTimeZone: { TimeZone(secondsFromGMT: 0)! }
        )
        let first = schedule(id: id(1), title: "Original", date: CalendarDate(year: 2026, month: 10, day: 2))
        let second = schedule(id: id(2), title: "Remove me", date: CalendarDate(year: 2026, month: 10, day: 3))
        _ = try store.write(schedules: [first, second])

        first.title = "Updated"
        first.date = CalendarDate(year: 2026, month: 10, day: 4)
        currentDate = date(2026, 10, 1, 13, 0)
        let replaced = try store.write(schedules: [first])

        XCTAssertEqual(replaced.generatedAt, currentDate)
        XCTAssertEqual(replaced.schedules.map(\.id), [first.id])
        XCTAssertEqual(replaced.schedules.first?.title, "Updated")
        XCTAssertEqual(replaced.schedules.first?.date, WidgetCalendarDate(year: 2026, month: 10, day: 4))
        XCTAssertEqual(store.read(), .success(replaced))

        let empty = try store.write(schedules: [])
        XCTAssertTrue(empty.schedules.isEmpty)
        XCTAssertEqual(store.read(), .success(empty))
    }

    func testAtomicReplacementAppliesWidgetProtectionEvenWhenPreviousFileIsUnprotected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: WidgetSnapshotStore.fileName)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: directory.path)
        try Data("old private title".utf8).write(to: fileURL, options: .noFileProtection)
        guard try FileManager.default.attributesOfItem(atPath: fileURL.path)[.protectionKey] != nil else {
            throw XCTSkip("File protection attributes require a physical iOS device")
        }
        let store = WidgetSnapshotStore(containerURL: { directory }, timelineReload: {})

        _ = try store.write(schedules: [])

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
    }

    func testReadDistinguishesMissingEmptyCorruptAndUnsupportedFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(containerURL: { directory })
        let fileURL = directory.appending(path: WidgetSnapshotStore.fileName)

        XCTAssertEqual(store.read(), .missing)

        try Data().write(to: fileURL)
        XCTAssertEqual(store.read(), .emptyFile)

        try Data("not-json".utf8).write(to: fileURL)
        XCTAssertEqual(store.read(), .corrupt)

        try Data(#"{"formatVersion":99,"generatedAt":0,"schedules":[]}"#.utf8).write(to: fileURL)
        XCTAssertEqual(store.read(), .unsupportedFormatVersion(99))
    }

    func testWriteFailureRemovesPrivatePreviousSnapshotAndRetryCanRegenerateIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalStore = WidgetSnapshotStore(containerURL: { directory })
        _ = try originalStore.write(schedules: [
            schedule(id: id(1), title: "Original", date: CalendarDate(year: 2027, month: 1, day: 1))
        ])
        var shouldFail = true
        let retryingStore = WidgetSnapshotStore(
            containerURL: { directory },
            atomicWrite: { data, url in
                if shouldFail {
                    shouldFail = false
                    throw TestError.writeFailed
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let replacement = schedule(
            id: id(2),
            title: "Replacement",
            date: CalendarDate(year: 2027, month: 2, day: 1)
        )

        XCTAssertThrowsError(try retryingStore.write(schedules: [replacement])) {
            XCTAssertEqual($0 as? WidgetSnapshotStoreError, .writeFailed)
        }
        XCTAssertEqual(originalStore.read(), .missing)

        let regenerated = try retryingStore.write(schedules: [replacement])
        XCTAssertEqual(regenerated.schedules.map(\.id), [replacement.id])
        XCTAssertEqual(originalStore.read(), .success(regenerated))
    }

    func testReadersSeeOnlyCompleteGenerationsWhileAtomicWritesReplaceSnapshot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generatedAt = date(2026, 10, 1, 12, 0)
        let store = WidgetSnapshotStore(
            containerURL: { directory },
            now: { generatedAt },
            deviceTimeZone: { TimeZone(secondsFromGMT: 0)! }
        )
        let firstGeneration = schedules(count: 600, title: "Generation A")
        let secondGeneration = schedules(count: 600, title: "Generation B")
        _ = try store.write(schedules: firstGeneration)

        let fileURL = directory.appending(path: WidgetSnapshotStore.fileName)
        let probe = ConcurrentReadProbe(expectedCount: 600)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while !probe.shouldStop {
                probe.record(WidgetSnapshotFileReader.read(fileURL: fileURL))
            }
            readerFinished.signal()
        }

        for index in 0..<30 {
            _ = try store.write(schedules: index.isMultiple(of: 2) ? secondGeneration : firstGeneration)
        }
        probe.stop()

        XCTAssertEqual(readerFinished.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(probe.readCount, 0)
        XCTAssertNil(probe.failure)
    }

    func testInvalidationRemovesPrivateSnapshotAndReloadsEvenWhenAlreadyAbsent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloadCount = 0
        let store = WidgetSnapshotStore(
            containerURL: { directory },
            timelineReload: { reloadCount += 1 }
        )
        _ = try store.write(schedules: [
            schedule(id: id(1), title: "Private title", date: CalendarDate(year: 2027, month: 1, day: 1))
        ])

        try store.invalidate()
        try store.invalidate()

        XCTAssertEqual(store.read(), .missing)
        XCTAssertEqual(reloadCount, 3)
    }

    func testUnavailableContainerIsDistinctAndCanBeRetried() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var available = false
        let store = WidgetSnapshotStore(containerURL: { available ? directory : nil })

        XCTAssertEqual(store.read(), .containerUnavailable)
        XCTAssertThrowsError(try store.write(schedules: [])) {
            XCTAssertEqual($0 as? WidgetSnapshotStoreError, .containerUnavailable)
        }

        available = true
        let regenerated = try store.write(schedules: [])
        XCTAssertEqual(store.read(), .success(regenerated))
    }

    func testConfiguredAppGroupContainerSupportsFileRoundTrip() throws {
        let containerURL = try XCTUnwrap(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupIdentifier
            )
        )
        let fileURL = containerURL.appending(path: "task-23-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let expected = Data("app-group-round-trip".utf8)

        try expected.write(to: fileURL, options: .atomic)

        XCTAssertEqual(try Data(contentsOf: fileURL), expected)
    }

    func testTimelineSkipsPassedTimedScheduleAndKeepsAllDayUntilLocalMidnight() {
        let timed = WidgetScheduleSnapshot(
            id: id(1),
            title: "Started",
            date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
            time: WidgetClockTime(hour: 9, minute: 0),
            timeZoneIdentifier: "UTC"
        )
        let allDay = WidgetScheduleSnapshot(
            id: id(2),
            title: "All day",
            date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
            time: nil,
            timeZoneIdentifier: "UTC"
        )
        let later = WidgetScheduleSnapshot(
            id: id(3),
            title: "Later",
            date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
            time: WidgetClockTime(hour: 11, minute: 0),
            timeZoneIdentifier: "UTC"
        )
        let snapshot = WidgetScheduleSnapshotFile(
            generatedAt: date(2026, 10, 1, 12, 0),
            schedules: [timed, allDay, later]
        )

        let plan = WidgetTimelinePlanner.plan(
            loadResult: .success(snapshot),
            now: date(2026, 10, 2, 10, 0),
            deviceTimeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(plan.presentations.map(\.id), [allDay.id, later.id])
        XCTAssertEqual(plan.nextRefreshDate, date(2026, 10, 2, 11, 0))

        let afterMidnight = WidgetTimelinePlanner.plan(
            loadResult: .success(snapshot),
            now: date(2026, 10, 3, 0, 0),
            deviceTimeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(afterMidnight.contentState, .empty)
    }

    func testTimelineUsesStoredTimeZoneForTimedDDayAndDeviceTimeZoneForAllDay() {
        let timed = WidgetScheduleSnapshot(
            id: id(1),
            title: "Seoul morning",
            date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
            time: WidgetClockTime(hour: 8, minute: 0),
            timeZoneIdentifier: "Asia/Seoul"
        )
        let allDay = WidgetScheduleSnapshot(
            id: id(2),
            title: "Local all day",
            date: WidgetCalendarDate(year: 2026, month: 10, day: 2),
            time: nil,
            timeZoneIdentifier: "Asia/Seoul"
        )
        let snapshot = WidgetScheduleSnapshotFile(
            generatedAt: date(2026, 10, 1, 12, 0),
            schedules: [allDay, timed]
        )

        let plan = WidgetTimelinePlanner.plan(
            loadResult: .success(snapshot),
            now: date(2026, 10, 1, 12, 0),
            deviceTimeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(plan.presentations.map(\.dDayText), ["D-1", "D-1"])
        XCTAssertEqual(plan.nextRefreshDate, date(2026, 10, 1, 15, 0))
    }

    func testTimelineDistinguishesEmptyContentFromUnreadableSnapshot() {
        let emptySnapshot = WidgetScheduleSnapshotFile(
            generatedAt: date(2026, 10, 1, 12, 0),
            schedules: []
        )

        XCTAssertEqual(
            WidgetTimelinePlanner.plan(
                loadResult: .success(emptySnapshot),
                now: date(2026, 10, 1, 12, 0),
                deviceTimeZone: TimeZone(secondsFromGMT: 0)!
            ).contentState,
            .empty
        )
        XCTAssertEqual(
            WidgetTimelinePlanner.plan(
                loadResult: .corrupt,
                now: date(2026, 10, 1, 12, 0),
                deviceTimeZone: TimeZone(secondsFromGMT: 0)!
            ).contentState,
            .unavailable
        )
    }

    func testScheduleDeepLinkRoundTripsAndRejectsMalformedURLs() throws {
        let scheduleID = id(42)

        let url = WidgetScheduleLink.url(for: scheduleID)

        XCTAssertEqual(WidgetScheduleLink.scheduleID(from: url), scheduleID)
        XCTAssertNil(WidgetScheduleLink.scheduleID(from: URL(string: "snapschedule://schedule/not-a-uuid")!))
        XCTAssertNil(WidgetScheduleLink.scheduleID(from: URL(string: "https://schedule/\(scheduleID)")!))
        XCTAssertNil(WidgetScheduleLink.scheduleID(from: URL(string: "snapschedule://other/\(scheduleID)")!))
    }

    func testFailedWriteAlsoRequestsTimelineReloadToDiscardCachedPrivateContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloadCount = 0
        var shouldFail = true
        let store = WidgetSnapshotStore(
            containerURL: { directory },
            atomicWrite: { data, url in
                if shouldFail {
                    shouldFail = false
                    throw TestError.writeFailed
                }
                try data.write(to: url, options: .atomic)
            },
            timelineReload: { reloadCount += 1 }
        )

        XCTAssertThrowsError(try store.write(schedules: []))
        XCTAssertEqual(reloadCount, 1)

        _ = try store.write(schedules: [])
        XCTAssertEqual(reloadCount, 2)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func schedule(
        id: UUID,
        title: String,
        date: CalendarDate,
        time: ClockTime? = nil,
        timeZoneIdentifier: String = "UTC"
    ) -> Schedule {
        Schedule(
            id: id,
            sourceCandidateID: UUID(),
            title: title,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            sourceAssetIdentifier: "private-asset-\(id.uuidString)"
        )
    }

    private func schedules(count: Int, title: String) -> [Schedule] {
        (1...count).map { value in
            schedule(
                id: id(value),
                title: title,
                date: CalendarDate(year: 2027, month: 1, day: 1),
                time: ClockTime(hour: 9, minute: value % 60)
            )
        }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "23000000-0000-0000-0000-%012d", value))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

private final class ConcurrentReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedCount: Int
    private var stopped = false
    private var storedReadCount = 0
    private var storedFailure: String?

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    var shouldStop: Bool {
        lock.withLock { stopped }
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    var failure: String? {
        lock.withLock { storedFailure }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    func record(_ result: WidgetSnapshotLoadResult) {
        lock.withLock {
            storedReadCount += 1
            guard storedFailure == nil else { return }
            guard case let .success(snapshot) = result else {
                storedFailure = "Reader observed non-snapshot result: \(result)"
                return
            }
            guard snapshot.schedules.count == expectedCount else {
                storedFailure = "Reader observed partial schedule count: \(snapshot.schedules.count)"
                return
            }
            let titles = Set(snapshot.schedules.map(\.title))
            guard titles == ["Generation A"] || titles == ["Generation B"] else {
                storedFailure = "Reader observed mixed generation titles: \(titles)"
                return
            }
        }
    }
}
