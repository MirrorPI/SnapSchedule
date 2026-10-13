import Foundation

enum WidgetScheduleSharing {
    static let appGroupIdentifier = "group.com.example.SnapSchedule"
    static let fileName = "widget-schedules.json"
}

enum WidgetSnapshotLoadResult: Equatable, Sendable {
    case success(WidgetScheduleSnapshotFile)
    case missing
    case emptyFile
    case corrupt
    case unsupportedFormatVersion(Int)
    case containerUnavailable
}

enum WidgetSnapshotFileReader {
    static func read(fileURL: URL) -> WidgetSnapshotLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .corrupt
        }
        guard !data.isEmpty else { return .emptyFile }

        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(VersionEnvelope.self, from: data).formatVersion else {
            return .corrupt
        }
        guard version == WidgetScheduleSnapshotFile.currentFormatVersion else {
            return .unsupportedFormatVersion(version)
        }
        guard let snapshot = try? decoder.decode(WidgetScheduleSnapshotFile.self, from: data) else {
            return .corrupt
        }
        return .success(snapshot)
    }
}

struct WidgetScheduleSnapshotFile: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let generatedAt: Date
    let schedules: [WidgetScheduleSnapshot]

    init(
        formatVersion: Int = currentFormatVersion,
        generatedAt: Date,
        schedules: [WidgetScheduleSnapshot]
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.schedules = schedules
    }
}

struct WidgetScheduleSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let date: WidgetCalendarDate
    let time: WidgetClockTime?
    let timeZoneIdentifier: String
}

struct WidgetCalendarDate: Codable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int
}

struct WidgetClockTime: Codable, Equatable, Sendable {
    let hour: Int
    let minute: Int
}

private struct VersionEnvelope: Decodable {
    let formatVersion: Int
}
