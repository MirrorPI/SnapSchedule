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
        return try makeProtected(configuration: configuration)
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
        return try makeProtected(configuration: configuration)
    }

    private static func makeProtected(configuration: ModelConfiguration) throws -> ModelContainer {
        // Keep SwiftData's resolved location, including the existing default store.
        // Core Data creates future SQLite files with AfterFirstUnlock protection.
        try protectExistingStoreFiles(at: configuration.url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        try protectExistingStoreFiles(at: configuration.url)
        return container
    }

    private static func protectExistingStoreFiles(at url: URL) throws {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            guard manager.fileExists(atPath: path) else { continue }
            let attributes = try manager.attributesOfItem(atPath: path)
            let protection = attributes[.protectionKey] as? FileProtectionType
            // Repair legacy unprotected files without weakening stronger classes.
            if protection == nil || protection == FileProtectionType.none {
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            }
        }
    }
}
