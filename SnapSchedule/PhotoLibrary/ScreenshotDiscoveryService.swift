import Foundation
import Photos

struct ScreenshotAssetMetadata: Equatable, Sendable {
    let assetIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenshotDiscoveryResult: Equatable, Sendable {
    case unavailable(PhotoLibraryAccess)
    case authorized([ScreenshotAssetMetadata])
    case limited([ScreenshotAssetMetadata])
}

actor ScreenshotDiscoveryService {
    typealias AssetFetcher = @Sendable (
        _ mediaType: PHAssetMediaType,
        _ options: PHFetchOptions
    ) -> [ScreenshotAssetMetadata]

    private let assetFetcher: AssetFetcher

    init(assetFetcher: @escaping AssetFetcher = ScreenshotDiscoveryService.fetchAssets) {
        self.assetFetcher = assetFetcher
    }

    func discover(access: PhotoLibraryAccess) -> ScreenshotDiscoveryResult {
        guard access.canReadAccessiblePhotos else {
            return .unavailable(access)
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )

        let assets = deduplicatedAndSorted(
            assetFetcher(.image, options)
        )

        switch access {
        case .authorized:
            return .authorized(assets)
        case .limited:
            return .limited(assets)
        case .notDetermined, .denied, .restricted:
            return .unavailable(access)
        }
    }

    private func deduplicatedAndSorted(
        _ assets: [ScreenshotAssetMetadata]
    ) -> [ScreenshotAssetMetadata] {
        var seenIdentifiers = Set<String>()

        return assets
            .sorted(by: Self.isOrderedBefore)
            .filter { seenIdentifiers.insert($0.assetIdentifier).inserted }
    }

    private static func isOrderedBefore(
        _ lhs: ScreenshotAssetMetadata,
        _ rhs: ScreenshotAssetMetadata
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.assetIdentifier < rhs.assetIdentifier
        }
    }

    private static func fetchAssets(
        mediaType: PHAssetMediaType,
        options: PHFetchOptions
    ) -> [ScreenshotAssetMetadata] {
        let fetchResult = PHAsset.fetchAssets(with: mediaType, options: options)
        var assets: [ScreenshotAssetMetadata] = []
        assets.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(
                ScreenshotAssetMetadata(
                    assetIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
            )
        }

        return assets
    }
}
