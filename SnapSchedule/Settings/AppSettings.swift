import Foundation
import Observation

@Observable
final class AppSettings {
    private enum Key {
        static let reminderDayBefore = "settings.reminderDayBefore"
        static let reminderSameDay = "settings.reminderSameDay"
        static let defaultExportToCalendar = "settings.defaultExportToCalendar"
        static let screenshotAnalysisBaselineDate = "scanning.screenshotAnalysisBaselineDate"
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    var reminderDayBefore: Bool {
        didSet { userDefaults.set(reminderDayBefore, forKey: Key.reminderDayBefore) }
    }

    var reminderSameDay: Bool {
        didSet { userDefaults.set(reminderSameDay, forKey: Key.reminderSameDay) }
    }

    var defaultExportToCalendar: Bool {
        didSet { userDefaults.set(defaultExportToCalendar, forKey: Key.defaultExportToCalendar) }
    }

    var screenshotAnalysisBaselineDate: Date? {
        didSet {
            if let screenshotAnalysisBaselineDate {
                userDefaults.set(
                    screenshotAnalysisBaselineDate,
                    forKey: Key.screenshotAnalysisBaselineDate
                )
            } else {
                userDefaults.removeObject(forKey: Key.screenshotAnalysisBaselineDate)
            }
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        reminderDayBefore = Self.value(
            forKey: Key.reminderDayBefore,
            defaultValue: true,
            userDefaults: userDefaults
        )
        reminderSameDay = Self.value(
            forKey: Key.reminderSameDay,
            defaultValue: true,
            userDefaults: userDefaults
        )
        defaultExportToCalendar = Self.value(
            forKey: Key.defaultExportToCalendar,
            defaultValue: false,
            userDefaults: userDefaults
        )
        screenshotAnalysisBaselineDate = userDefaults.object(
            forKey: Key.screenshotAnalysisBaselineDate
        ) as? Date
    }

    private static func value(
        forKey key: String,
        defaultValue: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }
}
