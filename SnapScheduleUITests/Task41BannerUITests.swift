import XCTest
import Vision

/// Read-only navigation on the installed Debug app. Never taps an ad or changes saved data.
@MainActor
final class Task41BannerUITests: XCTestCase {
    func testPhysicalBannerDisplayAndSettings() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone 14 Plus only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_UI_DEVICE_UDID"] == "00000000-0000000000000000" else {
            throw XCTSkip("Designated test phone required")
        }
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForTestAd(app), "Official Test mode pixels must be visible; never bypass a consent form.")
        capture(app, "Task41-iPhone14Plus-portrait-Test-Ad")
        let settings = app.buttons["설정"]
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 8))
        capture(app, "Task41-settings-touch")
        app.buttons["완료"].tap()
        XCTAssertTrue(waitForTestAd(app))
        #endif
    }

    func testPhysicalBannerCandidateAndScroll() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone 14 Plus only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_UI_DEVICE_UDID"] == "00000000-0000000000000000" else {
            throw XCTSkip("Designated test phone required")
        }
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForTestAd(app), "Official Test mode pixels must be visible; never bypass a consent form.")
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        capture(app, "Task41-candidate-touch-no-edit")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForTestAd(app))
        // Start the drag below the banner, away from every ad control.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.82))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.35)))
        capture(app, "Task41-scrolled-content")
        XCTAssertFalse(try words(app).joined().lowercased().replacingOccurrences(of: " ", with: "").contains("testmode"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.88)))
        XCTAssertTrue(waitForTestAd(app))
        #endif
    }

    func testPhysicalBannerRotation() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone 14 Plus only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_UI_DEVICE_UDID"] == "00000000-0000000000000000" else {
            throw XCTSkip("Designated test phone required")
        }
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForTestAd(app), "Official Test mode pixels must be visible; never bypass a consent form.")
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<30 {
            if app.frame.width > app.frame.height { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        capture(app, "Task41-landscape")
        print("[Task41] landscape device=\(XCUIDevice.shared.orientation.rawValue) appFrame=\(app.frame)")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The actual application must lay out in landscape.")
        XCTAssertTrue(waitForTestAd(app))
        capture(app, "Task41-landscape-Test-Ad")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForTestAd(app))
        capture(app, "Task41-restored-portrait")
        #endif
    }

    private func waitForTestAd(_ app: XCUIApplication) -> Bool {
        for _ in 0..<30 {
            if (try? words(app).joined().lowercased().replacingOccurrences(of: " ", with: "").contains("testmode")) == true { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        capture(app, "Task41-Test-Ad-not-visible")
        return false
    }
    private func words(_ app: XCUIApplication) throws -> [String] {
        let screenshot = XCUIScreen.main.screenshot()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: screenshot.pngRepresentation).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
