import XCTest

/// Navigation only on the dedicated design Simulator; never changes data or permission.
@MainActor
final class Task421DesignUITests: XCTestCase {
    func testTask43NativeTabsAndRotationWithLargestText() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Task43 isolated Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task43FinalReview"),
              ["DC2BEFD2-98F0-477B-AB32-294F8E659FCA", "9713C13F-7AB6-47F8-883A-FBF7125B1B3F"].contains(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "") else {
            throw XCTSkip("Explicit Task43 Simulator runner required")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for (language, locale) in [("ko", "ko_KR"), ("en", "en_US"), ("ja", "ja_JP")] {
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 10)); XCTAssertEqual(tabs.buttons.count, 3)
            tabs.buttons.element(boundBy: 0).tap(); capture(app, "task43-\(language)-native-candidates-AX5")
            tabs.buttons.element(boundBy: 2).tap(); capture(app, "task43-\(language)-native-settings-AX5")
            tabs.buttons.element(boundBy: 1).tap()
            let calendar = app.otherElements["home-calendar"]
            XCTAssertTrue(calendar.waitForExistence(timeout: 5)); capture(app, "task43-\(language)-native-home-portrait-AX5")
            let before = calendar.frame
            XCUIDevice.shared.orientation = .landscapeLeft
            var previousLandscapeFrame = CGRect.zero
            var stableFrames = 0
            let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = calendar.frame
                stableFrames = abs(frame.minY - previousLandscapeFrame.minY) < 0.5 && abs(frame.width - previousLandscapeFrame.width) < 0.5 ? stableFrames + 1 : 0
                previousLandscapeFrame = frame
                return app.frame.width > app.frame.height && frame.width > 0 && stableFrames >= 2
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 8), .completed)
            XCTAssertTrue(calendar.exists); capture(app, "task43-\(language)-native-home-landscape-AX5")
            tabs.buttons.element(boundBy: 0).tap(); capture(app, "task43-\(language)-native-candidates-landscape-AX5")
            tabs.buttons.element(boundBy: 1).tap()
            XCUIDevice.shared.orientation = .portrait
            let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height && abs(calendar.frame.minY - before.minY) < 1 }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 8), .completed)
            capture(app, "task43-\(language)-native-home-return-AX5")
            app.terminate()
        }
        #endif
    }

    func testThreeTabsOpenOnHomeAndKeepCalendarPosition() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Design Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "DC2BEFD2-98F0-477B-AB32-294F8E659FCA" else {
            throw XCTSkip("Dedicated Task42-1 Simulator only")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Three system tabs must replace Home entry buttons")
        let home = tabs.buttons["홈"]
        let candidates = tabs.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "일정 확인")).firstMatch
        let settings = tabs.buttons["설정"]
        XCTAssertTrue(home.isSelected)
        XCTAssertEqual(tabs.buttons.count, 3)
        XCTAssertFalse(app.buttons["후보 검수하기"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["home-analysis-status"].exists)
        let calendar = app.otherElements["home-calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        let before = calendar.frame
        capture(app, "tabs-home-before")
        candidates.tap()
        XCTAssertTrue(app.descendants(matching: .any)["candidate-review-status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["후보"].exists)
        XCTAssertFalse(app.staticTexts["분석할 새 스크린샷이 없습니다."].exists)
        capture(app, "tabs-candidates")
        settings.tap()
        XCTAssertTrue(app.navigationBars["설정"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["하루 전"].exists)
        XCTAssertTrue(app.switches["당일"].exists)
        XCTAssertTrue(app.switches["새 일정에서 Apple 캘린더 추가를 기본 선택"].exists)
        XCTAssertFalse(app.buttons["완료"].exists)
        capture(app, "tabs-settings")
        home.tap()
        XCTAssertTrue(home.isSelected)
        XCTAssertEqual(calendar.frame.minY, before.minY, accuracy: 1)
        capture(app, "tabs-home-return")
        if ProcessInfo.processInfo.arguments.contains("-Task421SkipRotation") { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        var lastLandscapeFrame = CGRect.zero
        var stableLandscapeFrames = 0
        let landscapeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = calendar.frame
            stableLandscapeFrames = abs(frame.minY - lastLandscapeFrame.minY) < 0.5
                && abs(frame.width - lastLandscapeFrame.width) < 0.5 ? stableLandscapeFrames + 1 : 0
            lastLandscapeFrame = frame
            print("[Task42-1 orientation] landscape app=\(app.frame) calendar=\(frame) stable=\(stableLandscapeFrames)")
            return app.frame.width > app.frame.height && frame.width > 0 && stableLandscapeFrames >= 2
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscapeReady], timeout: 5), .completed)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(calendar.exists)
        capture(app, "tabs-home-landscape")
        XCUIDevice.shared.orientation = .portrait
        let portraitReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = calendar.frame
            print("[Task42-1 orientation] portrait app=\(app.frame) calendar=\(frame) before=\(before)")
            return app.frame.width < app.frame.height && abs(frame.width - before.width) < 1
                && abs(frame.minY - before.minY) < 1
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [portraitReady], timeout: 5), .completed)
        XCTAssertTrue(home.isSelected)
        XCTAssertEqual(calendar.frame.minY, before.minY, accuracy: 1)
        capture(app, "tabs-home-portrait-return")
        #endif
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = name.contains("task43-") ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "task421-navigation-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
