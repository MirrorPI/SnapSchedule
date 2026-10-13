import Photos
import XCTest
@testable import SnapSchedule

@MainActor
final class ScreenshotDiscoveryServiceTests: XCTestCase {
    func testDiscoveryFetchesOutsideMainThread() async {
        let service = ScreenshotDiscoveryService { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            return []
        }

        _ = await service.discover(access: .authorized)
    }

    func testUnavailableAccessDoesNotFetchAssets() async {
        for access in [PhotoLibraryAccess.notDetermined, .denied, .restricted] {
            let fetchCount = LockedBox(0)
            let service = ScreenshotDiscoveryService { _, _ in
                fetchCount.withValue { $0 += 1 }
                return []
            }

            let result = await service.discover(access: access)

            XCTAssertEqual(result, .unavailable(access))
            XCTAssertEqual(fetchCount.withValue { $0 }, 0)
        }
    }

    func testAuthorizedEmptyLibraryReturnsAuthorizedEmptyResult() async {
        let service = ScreenshotDiscoveryService { _, _ in [] }

        let result = await service.discover(access: .authorized)

        XCTAssertEqual(result, .authorized([]))
    }

    func testLimitedAccessReturnsOnlyAccessibleMetadataAsLimitedResult() async {
        let accessible = ScreenshotAssetMetadata(
            assetIdentifier: "limited-screenshot",
            creationDate: nil,
            pixelWidth: 1179,
            pixelHeight: 2556
        )
        let service = ScreenshotDiscoveryService { _, _ in [accessible] }

        let result = await service.discover(access: .limited)

        XCTAssertEqual(result, .limited([accessible]))
    }

    func testDiscoveryUsesImageScreenshotQueryWithoutCreationDateCutoff() async {
        let capturedMediaType = LockedBox<PHAssetMediaType?>(nil)
        let capturedPredicate = LockedBox<NSPredicate?>(nil)
        let oldScreenshot = ScreenshotAssetMetadata(
            assetIdentifier: "old-screenshot",
            creationDate: Date(timeIntervalSince1970: 1),
            pixelWidth: 750,
            pixelHeight: 1334
        )
        let service = ScreenshotDiscoveryService { mediaType, options in
            capturedMediaType.withValue { $0 = mediaType }
            capturedPredicate.withValue { $0 = options.predicate }
            return [oldScreenshot]
        }

        let result = await service.discover(access: .authorized)

        XCTAssertEqual(capturedMediaType.withValue { $0 }, .image)
        let predicate = try? XCTUnwrap(capturedPredicate.withValue { $0 })
        XCTAssertTrue(
            predicate?.evaluate(
                with: ["mediaSubtype": PHAssetMediaSubtype.photoScreenshot.rawValue]
            ) == true
        )
        XCTAssertFalse(predicate?.evaluate(with: ["mediaSubtype": 0]) == true)
        XCTAssertFalse(predicate?.predicateFormat.contains("creationDate") == true)
        XCTAssertEqual(result, .authorized([oldScreenshot]))
    }

    func testDiscoveryRemovesDuplicateIdentifiersAndSortsByDateThenIdentifier() async {
        let oldest = ScreenshotAssetMetadata(
            assetIdentifier: "z-oldest",
            creationDate: Date(timeIntervalSince1970: 10),
            pixelWidth: 100,
            pixelHeight: 200
        )
        let sameDateFirst = ScreenshotAssetMetadata(
            assetIdentifier: "a-same-date",
            creationDate: Date(timeIntervalSince1970: 20),
            pixelWidth: 300,
            pixelHeight: 400
        )
        let sameDateSecond = ScreenshotAssetMetadata(
            assetIdentifier: "b-same-date",
            creationDate: Date(timeIntervalSince1970: 20),
            pixelWidth: 500,
            pixelHeight: 600
        )
        let missingDate = ScreenshotAssetMetadata(
            assetIdentifier: "no-date",
            creationDate: nil,
            pixelWidth: 700,
            pixelHeight: 800
        )
        let service = ScreenshotDiscoveryService { _, _ in
            [missingDate, sameDateSecond, oldest, sameDateFirst, oldest]
        }

        let result = await service.discover(access: .authorized)

        XCTAssertEqual(
            result,
            .authorized([oldest, sameDateFirst, sameDateSecond, missingDate])
        )
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
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
