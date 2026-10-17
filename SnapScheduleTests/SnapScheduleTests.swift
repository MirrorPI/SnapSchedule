import XCTest
import UIKit
@testable import SnapSchedule

@MainActor
final class SnapScheduleTests: XCTestCase {
    func testSceneDeactivationSynchronouslyCoversPersonalContentWithoutTakingKeyWindow() throws {
        let scene = try appScene()
        let originalKeyWindow = scene.keyWindow
        defer { activate(scene) }

        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)

        let cover = try XCTUnwrap(privacyWindow(in: scene), "Inactive scenes must be covered before the lifecycle notification returns")
        XCTAssertFalse(cover.isHidden)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertEqual(cover.bounds.size, scene.coordinateSpace.bounds.size)
        XCTAssertEqual(cover.rootViewController?.view.backgroundColor, .systemBackground)
        XCTAssertEqual(cover.rootViewController?.view.isOpaque, true)
        XCTAssertFalse(cover.isKeyWindow)
        XCTAssertTrue(scene.keyWindow === originalKeyWindow)
        XCTAssertTrue(scene.windows.filter { $0 !== cover && !$0.isHidden }.allSatisfy { $0.windowLevel < cover.windowLevel })
    }

    func testPrivacyCoverStaysAboveNewModalWindowsUntilMatchingSceneActivation() throws {
        let scene = try appScene()
        let modalWindow = UIWindow(windowScene: scene)
        modalWindow.rootViewController = UIViewController()
        defer {
            modalWindow.isHidden = true
            activate(scene)
        }
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        let cover = try XCTUnwrap(privacyWindow(in: scene))

        modalWindow.windowLevel = UIWindow.Level(rawValue: cover.windowLevel.rawValue + 100)
        modalWindow.isHidden = false

        XCTAssertGreaterThan(cover.windowLevel, modalWindow.windowLevel)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        XCTAssertTrue(privacyWindow(in: scene) === cover, "Repeated transitions must not accumulate privacy windows")
        // UIKit's own observers require a real scene on its global center.
        // Exercise our input guard directly instead of broadcasting invalid data.
        AppSnapshotPrivacyShield.shared.revealScene(
            Notification(name: UIScene.didActivateNotification, object: NSObject())
        )
        XCTAssertFalse(cover.isHidden, "Unrelated activation must not reveal this scene")

        activate(scene)

        XCTAssertTrue(cover.isHidden)
        XCTAssertNil(privacyWindow(in: scene))
        XCTAssertFalse(modalWindow.isHidden, "Restoring the app must preserve its existing windows")
    }

    func testSceneDisconnectRemovesPrivacyWindow() throws {
        let scene = try appScene()
        defer { activate(scene) }
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        let cover = try XCTUnwrap(privacyWindow(in: scene))

        NotificationCenter.default.post(name: UIScene.didDisconnectNotification, object: scene)

        XCTAssertTrue(cover.isHidden)
        XCTAssertNil(privacyWindow(in: scene))
    }

    private func appScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    private func privacyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first { $0.accessibilityIdentifier == "AppSnapshotPrivacyShield" && !$0.isHidden }
    }

    private func activate(_ scene: UIWindowScene) {
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    }
}
