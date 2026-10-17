import Foundation
import WidgetKit

enum WidgetSnapshotStoreError: Error, Equatable {
    case containerUnavailable
    case writeFailed
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
            try data.write(to: url, options: .atomic)
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

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try atomicWrite(data, containerURL.appending(path: Self.fileName))
            timelineReload()
            return snapshot
        } catch let error as WidgetSnapshotStoreError {
            throw error
        } catch {
            throw WidgetSnapshotStoreError.writeFailed
        }
    }

    func read() -> WidgetSnapshotLoadResult {
        guard let containerURL = containerURL() else { return .containerUnavailable }
        return WidgetSnapshotFileReader.read(
            fileURL: containerURL.appending(path: Self.fileName)
        )
    }
}
