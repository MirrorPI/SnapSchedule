import Foundation
import Observation
import SwiftData

enum ScanRunState: Equatable, Sendable {
    case waiting
    case discovering
    case analyzing
    case completed
    case completedWithFailures
    case failed
    case accessUnavailable
}

struct ScanStatus: Equatable, Sendable {
    var state: ScanRunState = .waiting
    var photoAccess: PhotoLibraryAccess = .notDetermined
    var targetImageCount = 0
    var completedImageCount = 0
    var failedImageCount = 0
    var pendingImageCount = 0
    var pendingCandidateCount = 0
    var excludedUndatedDraftCount = 0
    var excludedAppScreenDraftCount = 0
    var excludedAppScreenImageCount = 0
    var dismissedUndatedCandidateCount = 0
    var currentAssetIdentifier: String?
    var imageLoadPhase: ScreenshotImageLoadPhase?
    var lastErrorMessage: String?
}

@MainActor
@Observable
final class ScanCoordinator {
    typealias Discover = @MainActor (PhotoLibraryAccess) async -> ScreenshotDiscoveryResult
    typealias LoadImage = @MainActor (
        String,
        @escaping @Sendable (ScreenshotImageLoadPhase) -> Void
    ) async throws -> ScreenshotImageInput
    typealias RecognizeText = @MainActor (ScreenshotImageInput) async throws -> [RecognizedTextFragment]

    private(set) var status: ScanStatus

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let scanQueue: ScanQueue
    @ObservationIgnored private let candidateCreationService: CandidateCreationService
    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let loadImage: LoadImage
    @ObservationIgnored private let recognizeText: RecognizeText
    @ObservationIgnored private let parser: DateTimeParser
    @ObservationIgnored private let analysisDate: () -> Date
    @ObservationIgnored private let timeZone: () -> TimeZone
    @ObservationIgnored private let analysisVersion: String
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var queuedAccess: PhotoLibraryAccess?
    @ObservationIgnored private var imageLoadID: UUID?

    init(
        context: ModelContext,
        settings: AppSettings,
        discover: @escaping Discover,
        loadImage: @escaping LoadImage,
        recognizeText: @escaping RecognizeText,
        parser: DateTimeParser = DateTimeParser(),
        analysisDate: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current },
        analysisVersion: String = "vision3-parser2-filter1"
    ) {
        self.context = context
        self.settings = settings
        scanQueue = ScanQueue(context: context)
        candidateCreationService = CandidateCreationService(context: context, scanQueue: scanQueue)
        self.discover = discover
        self.loadImage = loadImage
        self.recognizeText = recognizeText
        self.parser = parser
        self.analysisDate = analysisDate
        self.timeZone = timeZone
        self.analysisVersion = analysisVersion
        status = ScanStatus(pendingCandidateCount: Self.pendingCandidateCount(in: context))
    }

    convenience init(
        context: ModelContext,
        settings: AppSettings = AppSettings()
    ) {
        let discoveryService = ScreenshotDiscoveryService()
        let imageLoader = ScreenshotImageLoader()
        let recognitionService = TextRecognitionService()
        self.init(
            context: context,
            settings: settings,
            discover: { access in
                await discoveryService.discover(access: access)
            },
            loadImage: { identifier, report in
                try await imageLoader.load(assetIdentifier: identifier, onPhase: report)
            },
            recognizeText: { input in
                try await recognitionService.recognize(input)
            }
        )
    }

    func activate(access: PhotoLibraryAccess) async {
        status.photoAccess = access
        if let activeTask {
            queuedAccess = access
            await activeTask.value
            guard self.activeTask == nil, let queuedAccess else { return }
            self.queuedAccess = nil
            await activate(access: queuedAccess)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(startingWith: access)
        }
        activeTask = task
        await task.value
    }

    func cancel() {
        queuedAccess = nil
        activeTask?.cancel()
    }

    private func runLoop(startingWith initialAccess: PhotoLibraryAccess) async {
        var nextAccess: PhotoLibraryAccess? = initialAccess
        while let access = nextAccess, !Task.isCancelled {
            queuedAccess = nil
            await runBatch(access: access)
            nextAccess = queuedAccess
        }
        activeTask = nil
    }

    private func runBatch(access: PhotoLibraryAccess) async {
        status = ScanStatus(
            state: .discovering,
            photoAccess: access,
            pendingCandidateCount: Self.pendingCandidateCount(in: context)
        )

        let analysisBaseline = analysisBaseline(for: access)
        let discovered = await discover(access)
        guard !Task.isCancelled else {
            status.state = .waiting
            return
        }

        let discovery = discoveryAfterAnalysisBaseline(
            discovered,
            baseline: analysisBaseline
        )

        do {
            try scanQueue.prepare(for: discovery)
        } catch {
            publishFatal(error)
            return
        }

        guard access.canReadAccessiblePhotos else {
            status.state = .accessUnavailable
            return
        }

        let metadata = Dictionary(
            uniqueKeysWithValues: discoveredAssets(in: discovery).map {
                ($0.assetIdentifier, $0)
            }
        )
        let batchIdentifiers: Set<String>
        do {
            batchIdentifiers = Set(
                try context.fetch(FetchDescriptor<ScreenshotScan>())
                    .filter { $0.status == .pending }
                    .map(\.assetIdentifier)
            )
        } catch {
            publishFatal(error)
            return
        }

        status.targetImageCount = batchIdentifiers.count
        status.pendingImageCount = batchIdentifiers.count
        guard !batchIdentifiers.isEmpty else {
            status.state = .completed
            return
        }

        let owner: UUID
        do {
            owner = try scanQueue.beginExecution()
        } catch {
            publishFatal(error)
            return
        }
        defer { try? scanQueue.endExecution(owner: owner) }

        while !Task.isCancelled {
            let scan: ScreenshotScan
            do {
                guard let claimed = try scanQueue.claimNext(owner: owner) else { break }
                scan = claimed
            } catch {
                publishFatal(error)
                return
            }

            guard batchIdentifiers.contains(scan.assetIdentifier) else {
                try? scanQueue.markRetryableFailure(
                    scan,
                    owner: owner,
                    code: "next-batch",
                    message: nil
                )
                break
            }

            status.state = .analyzing
            status.currentAssetIdentifier = scan.assetIdentifier
            status.imageLoadPhase = .loadingLocal
            let assetIdentifier = scan.assetIdentifier
            let loadID = UUID()
            imageLoadID = loadID
            defer {
                imageLoadID = nil
                status.currentAssetIdentifier = nil
                status.imageLoadPhase = nil
            }

            do {
                let input = try await loadImage(assetIdentifier) { [weak self] phase in
                    Task { @MainActor in
                        guard self?.imageLoadID == loadID else { return }
                        self?.status.imageLoadPhase = phase
                    }
                }
                imageLoadID = nil
                status.imageLoadPhase = nil
                try Task.checkCancellation()
                let fragments = try await recognizeText(input)
                try Task.checkCancellation()
                let analyzedAt = analysisDate()
                let drafts = parser.parse(
                    fragments: fragments,
                    captureDate: metadata[scan.assetIdentifier]?.creationDate,
                    analysisDate: analyzedAt,
                    timeZone: timeZone()
                )
                try candidateCreationService.completeAnalysis(
                    scan,
                    owner: owner,
                    drafts: drafts,
                    fragments: fragments,
                    settings: settings,
                    analysisVersion: analysisVersion,
                    analyzedAt: analyzedAt
                )
                let exclusions = candidateCreationService.lastExclusions
                status.excludedUndatedDraftCount += exclusions.undatedDraftCount
                status.excludedAppScreenDraftCount += exclusions.appScreenDraftCount
                status.excludedAppScreenImageCount += exclusions.appScreenImageCount
                status.completedImageCount += 1
                status.pendingCandidateCount = Self.pendingCandidateCount(in: context)
            } catch {
                if Task.isCancelled || isCancellation(error) {
                    try? scanQueue.markRetryableFailure(
                        scan,
                        owner: owner,
                        code: "interrupted",
                        message: nil
                    )
                    status.state = .waiting
                    updatePendingCount()
                    return
                }

                do {
                    if error as? ScreenshotImageLoadError == .inaccessible {
                        try scanQueue.markInaccessible(scan, owner: owner)
                    } else {
                        try scanQueue.markRetryableFailure(
                            scan,
                            owner: owner,
                            code: failureCode(for: error),
                            message: failureMessage(for: error)
                        )
                    }
                    status.failedImageCount += 1
                } catch {
                    publishFatal(error)
                    return
                }
            }

            updatePendingCount()
        }

        status.currentAssetIdentifier = nil
        status.imageLoadPhase = nil
        if Task.isCancelled {
            status.state = .waiting
        } else {
            status.state = status.failedImageCount == 0 ? .completed : .completedWithFailures
        }
    }

    private func updatePendingCount() {
        status.pendingImageCount = max(
            status.targetImageCount - status.completedImageCount - status.failedImageCount,
            0
        )
    }

    private func publishFatal(_ error: Error) {
        status.state = .failed
        status.currentAssetIdentifier = nil
        status.imageLoadPhase = nil
        status.lastErrorMessage = failureMessage(for: error)
        updatePendingCount()
    }

    private func discoveredAssets(
        in result: ScreenshotDiscoveryResult
    ) -> [ScreenshotAssetMetadata] {
        switch result {
        case .unavailable:
            return []
        case let .authorized(assets), let .limited(assets):
            return assets
        }
    }

    private func discoveryAfterAnalysisBaseline(
        _ result: ScreenshotDiscoveryResult,
        baseline: Date?
    ) -> ScreenshotDiscoveryResult {
        switch result {
        case .unavailable:
            return result
        case let .authorized(assets):
            return .authorized(assetsAfterAnalysisBaseline(assets, baseline: baseline))
        case let .limited(assets):
            return .limited(assetsAfterAnalysisBaseline(assets, baseline: baseline))
        }
    }

    private func analysisBaseline(for access: PhotoLibraryAccess) -> Date? {
        guard access.canReadAccessiblePhotos else { return nil }
        if let storedBaseline = settings.screenshotAnalysisBaselineDate {
            return storedBaseline
        }

        let baseline = analysisDate()
        settings.screenshotAnalysisBaselineDate = baseline
        return baseline
    }

    private func assetsAfterAnalysisBaseline(
        _ assets: [ScreenshotAssetMetadata],
        baseline: Date?
    ) -> [ScreenshotAssetMetadata] {
        guard let baseline else { return assets }

        return assets.filter { asset in
            guard let creationDate = asset.creationDate else { return false }
            return creationDate > baseline
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || error as? ScreenshotImageLoadError == .cancelled
            || error as? TextRecognitionError == .cancelled
    }

    private func failureCode(for error: Error) -> String {
        switch error {
        case ScreenshotImageLoadError.retryable(.local):
            return "image-local"
        case ScreenshotImageLoadError.retryable(.iCloud):
            return "image-icloud"
        case let TextRecognitionError.failed(domain, code):
            return "ocr-\(domain)-\(code)"
        default:
            let error = error as NSError
            return "analysis-\(error.domain)-\(error.code)"
        }
    }

    private func failureMessage(for error: Error) -> String {
        switch error {
        case ScreenshotImageLoadError.retryable(.local):
            return String(localized: "The image is temporarily unavailable.")
        case ScreenshotImageLoadError.retryable(.iCloud):
            return String(localized: "The iCloud image could not be downloaded.")
        case let TextRecognitionError.failed(domain, code):
            return String(localized: "Text recognition failed (\(domain) \(code)).")
        default:
            return String(localized: "Analysis could not be completed.")
        }
    }

    private static func pendingCandidateCount(in context: ModelContext) -> Int {
        CandidateReviewSummary(candidates: (try? context.fetch(FetchDescriptor<ScheduleCandidate>())) ?? []).pendingCount
    }
}
