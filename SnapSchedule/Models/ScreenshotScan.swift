import Foundation
import SwiftData

@Model
final class ScreenshotScan {
    @Attribute(.unique) private(set) var assetIdentifier: String
    var firstDiscoveredAt: Date
    private var statusRawValue: String
    var analyzedAt: Date?
    var analysisVersion: String?
    var failureCode: String?
    var failureMessage: String?
    var hasDateCandidates: Bool?

    var status: ScreenshotScanStatus {
        get { ScreenshotScanStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    init(
        assetIdentifier: String,
        firstDiscoveredAt: Date = .now,
        status: ScreenshotScanStatus = .pending,
        analyzedAt: Date? = nil,
        analysisVersion: String? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        hasDateCandidates: Bool? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.firstDiscoveredAt = firstDiscoveredAt
        statusRawValue = status.rawValue
        self.analyzedAt = analyzedAt
        self.analysisVersion = analysisVersion
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.hasDateCandidates = hasDateCandidates
    }
}
