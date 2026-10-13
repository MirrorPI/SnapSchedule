import Foundation
import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFirstLaunchUsesProductDefaultsWhenKeysAreMissing() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)

        XCTAssertTrue(settings.reminderDayBefore)
        XCTAssertTrue(settings.reminderSameDay)
        XCTAssertFalse(settings.defaultExportToCalendar)
    }

    func testExplicitFalseValuesRemainFalseAfterReload() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings: AppSettings? = AppSettings(userDefaults: defaults)
        settings?.reminderDayBefore = false
        settings?.reminderSameDay = false
        settings?.defaultExportToCalendar = true

        settings = nil
        let reloaded = AppSettings(userDefaults: defaults)

        XCTAssertFalse(reloaded.reminderDayBefore)
        XCTAssertFalse(reloaded.reminderSameDay)
        XCTAssertTrue(reloaded.defaultExportToCalendar)
    }

    func testScreenshotAnalysisBaselineStartsUnsetAndPersistsAfterReload() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings: AppSettings? = AppSettings(userDefaults: defaults)
        XCTAssertNil(settings?.screenshotAnalysisBaselineDate)
        let baseline = Date(timeIntervalSince1970: 1_000)

        settings?.screenshotAnalysisBaselineDate = baseline
        settings = nil
        let reloaded = AppSettings(userDefaults: defaults)

        XCTAssertEqual(reloaded.screenshotAnalysisBaselineDate, baseline)
    }

    func testChangingDefaultsDoesNotMutateAnExistingCandidate() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let store = LocalDataStore(container: container)
        let candidate = ScheduleCandidate(
            sourceAssetIdentifier: "asset",
            sourceCandidateKey: "candidate",
            title: "Existing",
            notifyDayBefore: false,
            notifySameDay: true,
            calendarExportRequested: false
        )
        try store.add(candidate)

        let settings = AppSettings(userDefaults: defaults)
        settings.reminderDayBefore = true
        settings.reminderSameDay = false
        settings.defaultExportToCalendar = true

        let storedCandidate = try XCTUnwrap(
            try store.context.fetch(FetchDescriptor<ScheduleCandidate>()).first
        )
        XCTAssertFalse(storedCandidate.notifyDayBefore)
        XCTAssertTrue(storedCandidate.notifySameDay)
        XCTAssertFalse(storedCandidate.calendarExportRequested)
    }

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
