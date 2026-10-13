import Photos
import XCTest
@testable import SnapSchedule

@MainActor
final class PhotoAuthorizationServiceTests: XCTestCase {
    func testReadWriteStatusesMapToExpectedAccessPolicy() {
        let cases: [(PHAuthorizationStatus, PhotoLibraryAccess, Bool, Bool)] = [
            (.notDetermined, .notDetermined, false, false),
            (.authorized, .authorized, true, true),
            (.limited, .limited, true, false),
            (.denied, .denied, false, false),
            (.restricted, .restricted, false, false),
        ]

        for (systemStatus, expectedAccess, canRead, hasFullAccess) in cases {
            let service = PhotoAuthorizationService(
                statusProvider: { systemStatus },
                authorizationRequester: { systemStatus }
            )

            XCTAssertEqual(service.access, expectedAccess)
            XCTAssertEqual(service.access.canReadAccessiblePhotos, canRead)
            XCTAssertEqual(service.access.hasFullAccess, hasFullAccess)
        }
    }

    func testRequestAccessPublishesReturnedStatus() async {
        var requestCount = 0
        let service = PhotoAuthorizationService(
            statusProvider: { .notDetermined },
            authorizationRequester: {
                requestCount += 1
                return .limited
            }
        )

        await service.requestAccess()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(service.access, .limited)
    }

    func testRefreshReadsChangedSystemStatus() {
        let systemStatus = AuthorizationStatusBox(.denied)
        let service = PhotoAuthorizationService(
            statusProvider: { systemStatus.value },
            authorizationRequester: { systemStatus.value }
        )
        systemStatus.value = .authorized

        service.refresh()

        XCTAssertEqual(service.access, .authorized)
    }
}

@MainActor
private final class AuthorizationStatusBox {
    var value: PHAuthorizationStatus

    init(_ value: PHAuthorizationStatus) {
        self.value = value
    }
}
