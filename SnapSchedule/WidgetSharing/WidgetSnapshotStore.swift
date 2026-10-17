import Foundation
import WidgetKit

enum WidgetSnapshotStoreError: Error, Equatable {
    case containerUnavailable
    case writeFailed
    case invalidationFailed
}

@MainActor
struct WidgetSnapshotStore {
    static let appGroupIdentifier = WidgetScheduleSharing.appGroupIdentifier
    static let fileName = WidgetScheduleSharing.fileName

    typealias ContainerURL = () -> URL?
    typealias AtomicWrite = (Data, URL) throws -> Void
    typealias TimelineReload = () -> Void

    private let containerURL: ContainerURL
    private let now: () -> Date
    private let deviceTimeZone: () -> TimeZone
    private let atomicWrite: AtomicWrite
    private let timelineReload: TimelineReload

    init(
        containerURL: @escaping ContainerURL = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupIdentifier
            )
        },
        now: @escaping () -> Date = Date.init,
        deviceTimeZone: @escaping () -> TimeZone = { .current },
        atomicWrite: @escaping AtomicWrite = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        },
        timelineReload: @escaping TimelineReload = {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetScheduleLink.widgetKind)
        }
    ) {
        self.containerURL = containerURL
        self.now = now
        self.deviceTimeZone = deviceTimeZone
        self.atomicWrite = atomicWrite
        self.timelineReload = timelineReload
    }

    @discardableResult
    func write(schedules: [Schedule]) throws -> WidgetScheduleSnapshotFile {
        guard let containerURL = containerURL() else {
            timelineReload()
            throw WidgetSnapshotStoreError.containerUnavailable
        }

        let generatedAt = now()
        let timeZone = deviceTimeZone()
        let schedulesByID = Dictionary(uniqueKeysWithValues: schedules.map { ($0.id, $0) })
        let items = ScheduleDatePresentation.upcoming(
            schedules,
            now: generatedAt,
            deviceTimeZone: timeZone
        ).compactMap { presentation -> WidgetScheduleSnapshot? in
            guard let schedule = schedulesByID[presentation.id] else { return nil }
            let storedTimeZoneIdentifier = schedule.timeZoneIdentifier.flatMap { identifier in
                TimeZone(identifier: identifier) == nil ? nil : identifier
            }
            return WidgetScheduleSnapshot(
                id: presentation.id,
                title: presentation.title,
                date: WidgetCalendarDate(
                    year: presentation.date.year,
                    month: presentation.date.month,
                    day: presentation.date.day
                ),
                time: presentation.time.map {
                    WidgetClockTime(hour: $0.hour, minute: $0.minute)
                },
                timeZoneIdentifier: storedTimeZoneIdentifier ?? presentation.effectiveTimeZoneIdentifier
            )
        }
        let snapshot = WidgetScheduleSnapshotFile(
            generatedAt: generatedAt,
            schedules: items
        )

        let fileURL = containerURL.appending(path: Self.fileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try atomicWrite(data, fileURL)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            timelineReload()
            return snapshot
        } catch {
            // A failed replacement must not leave an old, now-private title behind.
            try invalidate(fileURL: fileURL)
            throw WidgetSnapshotStoreError.writeFailed
        }
    }

    func invalidate() throws {
        guard let containerURL = containerURL() else {
            timelineReload()
            throw WidgetSnapshotStoreError.containerUnavailable
        }
        try invalidate(fileURL: containerURL.appending(path: Self.fileName))
    }

    private func invalidate(fileURL: URL) throws {
        defer { timelineReload() }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already absent is a successfully invalidated snapshot.
        } catch {
            throw WidgetSnapshotStoreError.invalidationFailed
        }
    }

    func read() -> WidgetSnapshotLoadResult {
        guard let containerURL = containerURL() else { return .containerUnavailable }
        return WidgetSnapshotFileReader.read(
            fileURL: containerURL.appending(path: Self.fileName)
        )
    }
}
