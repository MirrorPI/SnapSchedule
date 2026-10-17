import ImageIO
import Photos
import UIKit
import XCTest
@testable import SnapSchedule

final class ScreenshotImageLoaderTests: XCTestCase {

    func testPhotoKitAdapterRejectsOversizedBytesBeforePreviewDecoding() {
        let data = Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1)
        let event = ScreenshotPhotoKitEventAdapter.result(
            data: data, orientation: .up, info: nil, source: .local)
        guard case .failed = event else {
            return XCTFail("Oversized encoded data must not reach UIImage/Vision consumers")
        }
    }

    func testPhotoKitAdapterRejectsHugePixelDimensionsWithoutDecodingPixels() {
        let data = pngHeader(width: 9_000, height: 4_000)
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 9_000)
        let event = ScreenshotPhotoKitEventAdapter.result(
            data: data, orientation: .up, info: nil, source: .local)
        guard case .failed = event else {
            return XCTFail("36 million declared pixels must be rejected before any raster allocation")
        }
    }

    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        // Synthetic PNG header only: no user photo and no large raster allocation.
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        func appendChunk(_ name: String, _ bytes: [UInt8]) {
            let length = UInt32(bytes.count)
            data.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                UInt8((length >> 8) & 255), UInt8(length & 255)])
            let payload = Array(name.utf8) + bytes
            data.append(contentsOf: payload)
            var crc: UInt32 = 0xffff_ffff
            for byte in payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            crc ^= 0xffff_ffff
            data.append(contentsOf: [UInt8((crc >> 24) & 255), UInt8((crc >> 16) & 255),
                UInt8((crc >> 8) & 255), UInt8(crc & 255)])
        }
        var dimensions: [UInt8] = []
        for value in [width, height] {
            dimensions.append(UInt8((value >> 24) & 255))
            dimensions.append(UInt8((value >> 16) & 255))
            dimensions.append(UInt8((value >> 8) & 255))
            dimensions.append(UInt8(value & 255))
        }
        appendChunk("IHDR", dimensions + [1, 0, 0, 0, 0])
        // zlib-compressed 4,504,000 zero bytes: 4,000 rows of 9,000 one-bit pixels,
        // each with its filter byte. The fixture allocates only its 4.4KB encoding.
        let compressed: [UInt8] = [120, 156, 236, 193, 1, 1, 0, 0, 0, 128, 144, 254, 175, 238, 8, 10]
            + Array(repeating: 0, count: 4_094)
            + [128, 219, 131, 67, 2, 0, 0, 0, 0, 65, 255, 95, 187, 194, 6]
            + Array(repeating: 0, count: 269) + [156, 2, 189, 188, 0, 1]
        appendChunk("IDAT", compressed)
        appendChunk("IEND", [])
        return data
    }
    @MainActor
    func testPreviewModelShowsICloudProgressThenRetryableFailure() async {
        let model = ScreenshotPreviewModel(
            sourceScreenshotIdentifier: "cloud-asset"
        ) { identifier, onPhase in
            XCTAssertEqual(identifier, "cloud-asset")
            onPhase(.downloadingFromICloud(progress: 0.4))
            throw ScreenshotImageLoadError.retryable(.iCloud)
        }

        model.load()
        await waitUntil { model.status == .retryable(.iCloud) }

        XCTAssertEqual(model.status, .retryable(.iCloud))
        XCTAssertNil(model.image)
    }

    @MainActor
    func testPreviewModelShowsInaccessibleFailureWithoutDiscardingSourceIdentifier() async {
        let model = ScreenshotPreviewModel(
            sourceScreenshotIdentifier: "removed-asset"
        ) { _, _ in
            throw ScreenshotImageLoadError.inaccessible
        }

        model.load()
        await waitUntil { model.status == .inaccessible }

        XCTAssertEqual(model.sourceScreenshotIdentifier, "removed-asset")
        XCTAssertEqual(model.status, .inaccessible)
    }

    @MainActor
    func testPreviewModelCancelReleasesLoadedImage() async throws {
        let imageData = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3))
                .pngData { context in
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
                }
        )
        let model = ScreenshotPreviewModel(
            sourceScreenshotIdentifier: "local-asset"
        ) { _, _ in
            ScreenshotImageInput(data: imageData, orientation: .up)
        }

        model.load()
        await waitUntil { model.status == .ready }
        XCTAssertNotNil(model.image)

        model.cancel()

        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.image)
    }

    @MainActor
    func testPreviewModelCancelStopsAnInFlightLoad() async {
        let cancellationObserved = LockedImageLoaderBox(false)
        let model = ScreenshotPreviewModel(
            sourceScreenshotIdentifier: "slow-asset"
        ) { _, _ in
            do {
                try await Task.sleep(for: .seconds(10))
                return ScreenshotImageInput(data: Data(), orientation: .up)
            } catch {
                cancellationObserved.withValue { $0 = true }
                throw ScreenshotImageLoadError.cancelled
            }
        }

        model.load()
        model.cancel()
        await waitUntil { cancellationObserved.withValue { $0 } }

        XCTAssertTrue(cancellationObserved.withValue { $0 })
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.image)
    }

    @MainActor
    func testPreviewModelRetryIgnoresLatePhaseFromPreviousLoad() async {
        let attempt = LockedImageLoaderBox(0)
        let firstPhase = LockedImageLoaderBox<(@Sendable (ScreenshotImageLoadPhase) -> Void)?>(nil)
        let model = ScreenshotPreviewModel(
            sourceScreenshotIdentifier: "retry-asset"
        ) { _, onPhase in
            let currentAttempt = attempt.withValue {
                $0 += 1
                return $0
            }
            if currentAttempt == 1 {
                firstPhase.withValue { $0 = onPhase }
                throw ScreenshotImageLoadError.retryable(.local)
            }
            try await Task.sleep(for: .seconds(10))
            return ScreenshotImageInput(data: Data(), orientation: .up)
        }

        model.load()
        await waitUntil { model.status == .retryable(.local) }
        model.load()
        await waitUntil { attempt.withValue { $0 } == 2 }

        firstPhase.withValue { $0 }?(.downloadingFromICloud(progress: 0.7))
        await Task.yield()

        XCTAssertEqual(model.status, .loadingLocal)
        model.cancel()
    }

    func testLoadReturnsOnlyFinalImageDataWithItsOrientation() async throws {
        let first = ScreenshotImageInput(
            data: Data([0x01]),
            orientation: .left
        )
        let final = ScreenshotImageInput(
            data: Data([0x02, 0x03]),
            orientation: .rightMirrored
        )
        let loader = ScreenshotImageLoader { _, receive in
            receive(.degraded(first))
            receive(.completed(final))
            receive(.completed(first))
            return 1
        } cancelRequest: { _ in }

        let loaded = try await loader.load(assetIdentifier: "asset")

        XCTAssertEqual(loaded, final)
    }

    func testLoadReportsLocalLoadingBeforeReturningLocalImage() async throws {
        let phases = LockedImageLoaderBox<[ScreenshotImageLoadPhase]>([])
        let image = ScreenshotImageInput(data: Data([0x01]), orientation: .up)
        let loader = ScreenshotImageLoader { _, receive in
            receive(.completed(image))
            return 2
        } cancelRequest: { _ in }

        _ = try await loader.load(assetIdentifier: "local") { phase in
            phases.withValue { $0.append(phase) }
        }

        XCTAssertEqual(phases.withValue { $0 }, [.loadingLocal])
    }

    func testLoadReportsICloudDownloadProgressAndKeepsCloudFailureDistinct() async {
        let phases = LockedImageLoaderBox<[ScreenshotImageLoadPhase]>([])
        let loader = ScreenshotImageLoader { _, receive in
            receive(.iCloudProgress(0.25))
            receive(.failed(.retryable(.iCloud)))
            return 3
        } cancelRequest: { _ in }

        do {
            _ = try await loader.load(assetIdentifier: "cloud") { phase in
                phases.withValue { $0.append(phase) }
            }
            XCTFail("Expected iCloud download failure")
        } catch {
            XCTAssertEqual(error as? ScreenshotImageLoadError, .retryable(.iCloud))
        }

        XCTAssertEqual(
            phases.withValue { $0 },
            [.loadingLocal, .downloadingFromICloud(progress: 0.25)]
        )
    }

    func testLoadPreservesInaccessibleFailure() async {
        let loader = ScreenshotImageLoader { _, receive in
            receive(.failed(.inaccessible))
            return 4
        } cancelRequest: { _ in }

        do {
            _ = try await loader.load(assetIdentifier: "missing")
            XCTFail("Expected inaccessible failure")
        } catch {
            XCTAssertEqual(error as? ScreenshotImageLoadError, .inaccessible)
        }
    }

    func testTaskCancellationCancelsPhotoKitRequestAndThrowsCancelled() async {
        let receiveBox = LockedImageLoaderBox<ScreenshotImageLoader.EventReceiver?>(nil)
        let cancelledRequestIDs = LockedImageLoaderBox<[PHImageRequestID]>([])
        let loader = ScreenshotImageLoader { _, receive in
            receiveBox.withValue { $0 = receive }
            return 42
        } cancelRequest: { requestID in
            cancelledRequestIDs.withValue { $0.append(requestID) }
        }
        let task = Task {
            try await loader.load(assetIdentifier: "cloud")
        }

        for _ in 0..<1_000 where receiveBox.withValue({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard receiveBox.withValue({ $0 }) != nil else {
            XCTFail("Image request did not start")
            task.cancel()
            return
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ScreenshotImageLoadError, .cancelled)
        }
        XCTAssertEqual(cancelledRequestIDs.withValue { $0 }, [42])
    }

    func testCompletionWaitsForAdmittedProgressCallbackToFinish() async throws {
        let receiveBox = LockedImageLoaderBox<ScreenshotImageLoader.EventReceiver?>(nil)
        let phaseEntered = DispatchSemaphore(value: 0)
        let releasePhase = DispatchSemaphore(value: 0)
        let loadReturned = DispatchSemaphore(value: 0)
        let final = ScreenshotImageInput(data: Data([0x01]), orientation: .up)
        let loader = ScreenshotImageLoader { _, receive in
            receiveBox.withValue { $0 = receive }
            return 50
        } cancelRequest: { _ in }
        let task = Task {
            let value = try await loader.load(assetIdentifier: "race") { phase in
                guard case .downloadingFromICloud = phase else { return }
                phaseEntered.signal()
                releasePhase.wait()
            }
            loadReturned.signal()
            return value
        }

        for _ in 0..<1_000 where receiveBox.withValue({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let receive = try XCTUnwrap(receiveBox.withValue { $0 })
        DispatchQueue.global().async {
            receive(.iCloudProgress(0.5))
        }
        let phaseEntryResult = await waitForSemaphore(
            phaseEntered,
            timeout: .now() + 1
        )
        XCTAssertEqual(phaseEntryResult, .success)
        DispatchQueue.global().async {
            receive(.completed(final))
        }
        let returnedBeforePhaseFinished = await waitForSemaphore(
            loadReturned,
            timeout: .now() + 0.1
        )
        releasePhase.signal()

        let loaded = try await task.value
        XCTAssertEqual(returnedBeforePhaseFinished, .timedOut)
        XCTAssertEqual(loaded, final)
    }

    func testPhotoKitAdapterClassifiesResultMetadata() {
        let accessDenied = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.accessUserDenied.rawValue
        )

        XCTAssertEqual(
            ScreenshotPhotoKitEventAdapter.result(
                data: nil,
                orientation: .up,
                info: [PHImageCancelledKey: true],
                source: .local
            ),
            .failed(.cancelled)
        )
        XCTAssertEqual(
            ScreenshotPhotoKitEventAdapter.result(
                data: nil,
                orientation: .up,
                info: [PHImageErrorKey: accessDenied],
                source: .local
            ),
            .failed(.inaccessible)
        )
        XCTAssertEqual(
            ScreenshotPhotoKitEventAdapter.result(
                data: nil,
                orientation: .up,
                info: [PHImageResultIsInCloudKey: true],
                source: .local
            ),
            .failed(.retryable(.iCloud))
        )
        XCTAssertEqual(
            ScreenshotPhotoKitEventAdapter.result(
                data: nil,
                orientation: .up,
                info: nil,
                source: .local
            ),
            .failed(.retryable(.local))
        )
    }

    func testPhotoKitAdapterClampsProgressAndClassifiesCloudError() {
        let networkError = NSError(
            domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.networkError.rawValue
        )

        XCTAssertEqual(
            ScreenshotPhotoKitEventAdapter.progress(1.5, error: networkError),
            [
                .iCloudProgress(1),
                .failed(.retryable(.iCloud)),
            ]
        )
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

private final class LockedImageLoaderBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
