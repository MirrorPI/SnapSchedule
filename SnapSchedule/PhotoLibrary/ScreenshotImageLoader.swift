import Foundation
import ImageIO
import Photos
import UIKit

struct ScreenshotImageInput: Equatable, Sendable {
    let data: Data
    let orientation: CGImagePropertyOrientation
}

enum ScreenshotImageLoadSource: Equatable, Sendable {
    case local
    case iCloud
}

enum ScreenshotImageLoadPhase: Equatable, Sendable {
    case loadingLocal
    case downloadingFromICloud(progress: Double)
}

enum ScreenshotImageLoadError: Error, Equatable, Sendable {
    case retryable(ScreenshotImageLoadSource)
    case inaccessible
    case cancelled
}

enum ScreenshotImageRequestEvent: Equatable, Sendable {
    case iCloudProgress(Double)
    case degraded(ScreenshotImageInput)
    case completed(ScreenshotImageInput)
    case failed(ScreenshotImageLoadError)
}

enum ScreenshotPhotoKitEventAdapter {
    static func progress(
        _ progress: Double,
        error: Error?
    ) -> [ScreenshotImageRequestEvent] {
        var events: [ScreenshotImageRequestEvent] = [
            .iCloudProgress(min(max(progress, 0), 1))
        ]
        if let error {
            events.append(.failed(classify(error: error, source: .iCloud)))
        }
        return events
    }

    static func result(
        data: Data?,
        orientation: CGImagePropertyOrientation,
        info: [AnyHashable: Any]?,
        source: ScreenshotImageLoadSource
    ) -> ScreenshotImageRequestEvent {
        if boolValue(PHImageCancelledKey, in: info) {
            return .failed(.cancelled)
        }
        if let error = info?[PHImageErrorKey] as? Error {
            return .failed(classify(error: error, source: source))
        }
        guard let data else {
            return .failed(
                boolValue(PHImageResultIsInCloudKey, in: info)
                    ? .retryable(.iCloud)
                    : .retryable(source)
            )
        }

        let input = ScreenshotImageInput(data: data, orientation: orientation)
        return boolValue(PHImageResultIsDegradedKey, in: info)
            ? .degraded(input)
            : .completed(input)
    }

    private static func boolValue(
        _ key: String,
        in info: [AnyHashable: Any]?
    ) -> Bool {
        if let value = info?[key] as? Bool {
            return value
        }
        return (info?[key] as? NSNumber)?.boolValue == true
    }

    private static func classify(
        error: Error,
        source: ScreenshotImageLoadSource
    ) -> ScreenshotImageLoadError {
        let error = error as NSError
        guard error.domain == PHPhotosErrorDomain else {
            return .retryable(source)
        }

        switch PHPhotosError.Code(rawValue: error.code) {
        case .userCancelled:
            return .cancelled
        case .identifierNotFound, .missingResource, .accessRestricted, .accessUserDenied:
            return .inaccessible
        default:
            return .retryable(source)
        }
    }
}

final class ScreenshotImageLoader: Sendable {
    typealias EventReceiver = @Sendable (ScreenshotImageRequestEvent) -> Void
    typealias Request = @Sendable (
        _ assetIdentifier: String,
        _ receive: @escaping EventReceiver
    ) -> PHImageRequestID
    typealias CancelRequest = @Sendable (PHImageRequestID) -> Void

    private let request: Request
    private let cancelRequest: CancelRequest

    init(
        request: @escaping Request,
        cancelRequest: @escaping CancelRequest
    ) {
        self.request = request
        self.cancelRequest = cancelRequest
    }

    convenience init(imageManager: PHImageManager = .default(), targetPixelSize: CGSize? = nil) {
        self.init(
            request: Self.photoKitRequest(using: imageManager, targetPixelSize: targetPixelSize),
            cancelRequest: { imageManager.cancelImageRequest($0) }
        )
    }

    func load(
        assetIdentifier: String,
        onPhase: @escaping @Sendable (ScreenshotImageLoadPhase) -> Void = { _ in }
    ) async throws -> ScreenshotImageInput {
        let operation = ScreenshotImageLoadOperation(
            cancelRequest: cancelRequest,
            onPhase: onPhase
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.install(continuation) else { return }
                operation.report(.loadingLocal)
                let requestID = request(assetIdentifier, operation.receive)
                operation.setRequestID(requestID)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private static func photoKitRequest(using imageManager: PHImageManager, targetPixelSize: CGSize?) -> Request {
        { assetIdentifier, receive in
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetIdentifier],
                options: nil
            )
            guard let asset = assets.firstObject else {
                receive(.failed(.inaccessible))
                return PHInvalidImageRequestID
            }

            let requestState = ScreenshotPhotoKitRequestState()
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.progressHandler = { progress, error, stop, _ in
                requestState.markICloudDownload()
                for event in ScreenshotPhotoKitEventAdapter.progress(
                    progress,
                    error: error
                ) {
                    receive(event)
                }
                if error != nil {
                    stop.pointee = true
                }
            }

            if let targetPixelSize {
                options.resizeMode = .exact
                return imageManager.requestImage(
                    for: asset, targetSize: targetPixelSize, contentMode: .aspectFit, options: options
                ) { image, info in
                    let source: ScreenshotImageLoadSource = requestState.usedICloudDownload ? .iCloud : .local
                    receive(ScreenshotPhotoKitEventAdapter.result(
                        data: image?.pngData(),
                        orientation: image.map { Self.orientation($0.imageOrientation) } ?? .up,
                        info: info, source: source
                    ))
                }
            }

            return imageManager.requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, orientation, info in
                let source: ScreenshotImageLoadSource = requestState.usedICloudDownload
                    ? .iCloud
                    : .local
                receive(
                    ScreenshotPhotoKitEventAdapter.result(
                        data: data,
                        orientation: orientation,
                        info: info,
                        source: source
                    )
                )
            }
        }
    }

    private static func orientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

private final class ScreenshotImageLoadOperation: @unchecked Sendable {
    private let eventQueue = DispatchQueue(
        label: "com.example.SnapSchedule.ScreenshotImageLoadOperation"
    )
    private let cancelRequest: ScreenshotImageLoader.CancelRequest
    private let onPhase: @Sendable (ScreenshotImageLoadPhase) -> Void
    private var continuation: CheckedContinuation<ScreenshotImageInput, Error>?
    private var requestID = PHInvalidImageRequestID
    private var cancellationRequested = false
    private var isFinished = false

    init(
        cancelRequest: @escaping ScreenshotImageLoader.CancelRequest,
        onPhase: @escaping @Sendable (ScreenshotImageLoadPhase) -> Void
    ) {
        self.cancelRequest = cancelRequest
        self.onPhase = onPhase
    }

    var receive: ScreenshotImageLoader.EventReceiver {
        { [weak self] event in
            self?.handle(event)
        }
    }

    func install(_ continuation: CheckedContinuation<ScreenshotImageInput, Error>) -> Bool {
        let installed = eventQueue.sync {
            guard !cancellationRequested else {
                isFinished = true
                return false
            }
            self.continuation = continuation
            return true
        }
        if !installed {
            continuation.resume(throwing: ScreenshotImageLoadError.cancelled)
        }
        return installed
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        eventQueue.async { [self] in
            self.requestID = requestID
            if cancellationRequested, requestID != PHInvalidImageRequestID {
                cancelRequest(requestID)
            }
        }
    }

    func report(_ phase: ScreenshotImageLoadPhase) {
        eventQueue.async { [self] in
            guard !isFinished else { return }
            onPhase(phase)
        }
    }

    func cancel() {
        eventQueue.async { [self] in
            guard !isFinished else { return }
            cancellationRequested = true
            let continuation = continuation
            self.continuation = nil
            if continuation != nil {
                isFinished = true
            }

            if requestID != PHInvalidImageRequestID {
                cancelRequest(requestID)
            }
            continuation?.resume(throwing: ScreenshotImageLoadError.cancelled)
        }
    }

    private func handle(_ event: ScreenshotImageRequestEvent) {
        eventQueue.async { [self] in
            guard !isFinished else { return }
            switch event {
            case let .iCloudProgress(progress):
                onPhase(.downloadingFromICloud(progress: progress))
            case .degraded:
                break
            case let .completed(input):
                finishOnEventQueue(with: .success(input))
            case let .failed(error):
                finishOnEventQueue(with: .failure(error))
            }
        }
    }

    private func finishOnEventQueue(with result: Result<ScreenshotImageInput, Error>) {
        guard !isFinished, let continuation else {
            return
        }
        isFinished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private final class ScreenshotPhotoKitRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var isDownloadingFromICloud = false

    var usedICloudDownload: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDownloadingFromICloud
    }

    func markICloudDownload() {
        lock.lock()
        isDownloadingFromICloud = true
        lock.unlock()
    }
}
