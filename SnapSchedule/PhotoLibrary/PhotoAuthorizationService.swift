import Observation
import Photos

enum PhotoLibraryAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited
    case denied
    case restricted

    var canReadAccessiblePhotos: Bool {
        self == .authorized || self == .limited
    }

    var hasFullAccess: Bool {
        self == .authorized
    }

    init(systemStatus: PHAuthorizationStatus) {
        switch systemStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }
}

@MainActor
@Observable
final class PhotoAuthorizationService {
    typealias StatusProvider = @MainActor () -> PHAuthorizationStatus
    typealias AuthorizationRequester = @MainActor () async -> PHAuthorizationStatus

    private(set) var access: PhotoLibraryAccess

    @ObservationIgnored private let statusProvider: StatusProvider
    @ObservationIgnored private let authorizationRequester: AuthorizationRequester

    init(
        statusProvider: @escaping StatusProvider = {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        },
        authorizationRequester: @escaping AuthorizationRequester = {
            await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
    ) {
        self.statusProvider = statusProvider
        self.authorizationRequester = authorizationRequester
        access = PhotoLibraryAccess(systemStatus: statusProvider())
    }

    func requestAccess() async {
        let status = await authorizationRequester()
        access = PhotoLibraryAccess(systemStatus: status)
    }

    func refresh() {
        access = PhotoLibraryAccess(systemStatus: statusProvider())
    }
}
