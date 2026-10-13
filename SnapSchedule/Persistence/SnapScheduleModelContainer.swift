import Foundation
import SwiftData

enum SnapScheduleModelContainer {
    private static let schema = Schema([
        ScreenshotScan.self,
        ScheduleCandidate.self,
        Schedule.self,
    ])

    static func make(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "SnapSchedule",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "SnapSchedule",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func makeDefault() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "SnapSchedule",
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
