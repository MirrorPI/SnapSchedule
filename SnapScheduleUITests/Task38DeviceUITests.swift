import XCTest

/// Opt-in USB validation of the actual installed app. No fixtures, store injection,
/// permission grants, photo changes, or Calendar writes in the navigation probe.
@MainActor
final class Task38DeviceUITests: XCTestCase {
    // Explicitly authorized on 2026-10-05. Only new namespaced fixtures may be edited.
    func testUSBAuthorizedNewFixtureStep() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 900
        let env = ProcessInfo.processInfo.environment
        let step = try XCTUnwrap(env["TASK38_NEW_FIXTURE_STEP"])
        let marker = try XCTUnwrap(env["TASK38_NEW_FIXTURE_MARKER"])
        XCTAssertTrue(["Task38 USB A1005", "Task38 USB B1005", "Task38 USB C1005", "Task38 USB D1005"].contains(marker))
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        switch step {
        case "create-note":
            notes.activate()
            XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
            if notes.buttons["메모"].exists { notes.buttons["메모"].tap() }
            let compose = notes.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR identifier == %@ OR label == %@", "새로운 메모", "메모 작성", "Compose", "작성")).firstMatch
            XCTAssertTrue(compose.waitForExistence(timeout: 5) && compose.isHittable)
            compose.tap()
            let field = notes.textViews.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            let initial = field.value as? String ?? ""
            XCTAssertTrue(initial.isEmpty || initial == "메모")
            field.tap()
            field.typeText(marker + "\n2026년 10월 7일 오후 4시\n장소: 테스트룸")
            XCTAssertTrue((field.value as? String ?? "").contains(marker))
            if notes.buttons["완료"].exists { notes.buttons["완료"].tap() }
            autonomyCaptureTree(notes, "USB authorized new note " + marker)
            if env["TASK38_CAPTURE_NEW_NOTE"] == "1" {
                let settings = authorizedCaptureSettings()
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                setSwitch(settings.switches["AssistiveTouch"], to: true)
                notes.activate(); Thread.sleep(forTimeInterval: 1.5)
                XCTAssertEqual(notes.state, .runningForeground)
                XCTAssertTrue((field.value as? String ?? "").contains(marker))
                XCTAssertEqual(board.frame, CGRect(x: 0, y: 0, width: 428, height: 926))
                // Same-session native menus visually verified in capture-menu/device/more-a.
                for point in [(0.725, 0.956), (0.70, 0.72), (0.62, 0.85), (0.705, 0.655)] {
                    board.coordinate(withNormalizedOffset: CGVector(dx: point.0, dy: point.1)).tap()
                    Thread.sleep(forTimeInterval: 0.8)
                    attach(board, name: "USB new note native capture menu " + marker)
                }
                Thread.sleep(forTimeInterval: 2)
                settings.activate(); Thread.sleep(forTimeInterval: 1)
                setSwitch(settings.switches["AssistiveTouch"], to: false)
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                print("[Task38 authorized fixture] native screenshot requested marker=\(marker); capture setting restored OFF")
            }
        case "enable-capture":
            let settings = authorizedCaptureSettings()
            XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
            setSwitch(settings.switches["AssistiveTouch"], to: true)
            notes.activate()
            XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains(marker))
            autonomyCaptureTree(board, "USB authorized capture floating control current viewport")
            attach(notes, name: "USB authorized new note before native capture")
        case "capture-observed-control":
            XCTAssertEqual(notes.state, .runningForeground)
            XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains(marker))
            let x = try XCTUnwrap(Double(env["TASK38_OBSERVED_X"] ?? ""))
            let y = try XCTUnwrap(Double(env["TASK38_OBSERVED_Y"] ?? ""))
            XCTAssertTrue((0...1).contains(x) && (0...1).contains(y))
            board.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
            autonomyCaptureTree(board, "USB authorized native capture next observed menu")
        case "restore-capture":
            let settings = authorizedCaptureSettings()
            setSwitch(settings.switches["AssistiveTouch"], to: false)
            XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
            attach(settings, name: "USB authorized native capture setting restored")
        case "inspect-candidates":
            let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
            app.launchArguments = []; app.launch()
            let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 30))
            review.tap()
            autonomyCaptureTree(app, "USB authorized new candidates after actual native capture")
        case "review-new-candidate":
            let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
            app.launchArguments = []; app.launch()
            let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 20)); review.tap()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "candidate-image-", marker))
            XCTAssertEqual(row.count, 1)
            reveal(row.firstMatch, in: app); row.firstMatch.tap()
            XCTAssertEqual(app.textFields["제목"].value as? String, marker + " · 장소: 테스트룸")
            let confirmation = app.switches["추정한 시간대 확인"]
            reveal(confirmation, in: app); setSwitch(confirmation, to: true)
            let calendar = app.switches["등록 후 캘린더에 추가"]
            reveal(calendar, in: app)
            setSwitch(calendar, to: env["TASK38_NEW_CALENDAR"] == "1")
            app.navigationBars.buttons["저장"].tap()
            autonomyCaptureTree(app, "USB authorized new candidate review saved")
        case "register-new-candidate":
            let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
            app.launchArguments = []; app.launch()
            let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 20)); review.tap()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "candidate-image-", marker))
            XCTAssertEqual(row.count, 1)
            reveal(row.firstMatch, in: app); row.firstMatch.tap()
            XCTAssertEqual(app.textFields["제목"].value as? String, marker + " · 장소: 테스트룸")
            let register = app.buttons["후보 등록"]
            reveal(register, in: app)
            XCTAssertTrue(register.isEnabled)
            attach(app, name: "USB authorized normal registration before tap " + marker)
            if env["TASK38_EXPECT_INTERRUPTION"] == "1" {
                print("[Task38 commit] READY_FOR_DEBUGGER marker=\(marker) epoch=\(Date().timeIntervalSince1970)")
                Thread.sleep(forTimeInterval: 45)
            }
            register.tap()
            if env["TASK38_EXPECT_INTERRUPTION"] == "1" {
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "External debugger must document real commit boundary and kill")
                app.launchArguments = []; app.launch()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
                autonomyCaptureTree(app, "USB authorized interrupted registration new process " + marker)
            } else {
                XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 20))
                autonomyCaptureTree(app, "USB authorized normal registration result " + marker)
                app.alerts.buttons["확인"].tap()
                app.terminate(); app.launchArguments = []; app.launch()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
                autonomyCaptureTree(app, "USB authorized registration new process " + marker)
            }
        case "inspect-native-calendar":
            let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
            calendar.activate(); Thread.sleep(forTimeInterval: 1.5)
            autonomyCaptureTree(calendar, "USB authorized same-phone Calendar current viewport")
        case "calendar-observed-navigation":
            let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
            calendar.activate(); Thread.sleep(forTimeInterval: 1)
            let label = try XCTUnwrap(env["TASK38_CALENDAR_NAVIGATION"])
            XCTAssertTrue(["10월 5일", "10월 7일 수요일", "10월 7일", "10월", "뒤로"].contains(label))
            let button = calendar.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
            XCTAssertTrue(calendar.frame.contains(button.frame))
            button.tap(); Thread.sleep(forTimeInterval: 1)
            autonomyCaptureTree(calendar, "USB authorized Calendar observed date navigation " + label)
        case "calendar-owned-event":
            let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
            calendar.activate(); Thread.sleep(forTimeInterval: 1)
            let event = calendar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", marker))
            for _ in 0..<3 {
                if event.firstMatch.exists && event.firstMatch.isHittable { break }
                calendar.swipeUp()
            }
            XCTAssertEqual(event.count, 1, "Count is limited to observed same-phone test-day event controls")
            let off = calendar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Task38 USB A1005"))
            XCTAssertEqual(off.count, 0)
            print("[Task38 authorized Calendar] observedTestDayCount=\(event.count) event=\(event.firstMatch.label) CalendarOFFAControls=\(off.count); not account-wide")
            autonomyCaptureTree(calendar, "USB authorized Calendar new event count in observed day viewport")
            event.firstMatch.tap()
            XCTAssertTrue(calendar.buttons["편집"].waitForExistence(timeout: 8))
            XCTAssertTrue(calendar.staticTexts[marker + " · 장소: 테스트룸"].exists)
            autonomyCaptureTree(calendar, "USB authorized Calendar owned event detail " + marker)
        case "calendar-delete-owned-event":
            XCTAssertEqual(marker, "Task38 USB B1005")
            let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
            calendar.activate(); Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(calendar.staticTexts[marker + " · 장소: 테스트룸"].exists)
            XCTAssertTrue(calendar.staticTexts["2026년 10월 7일 수요일"].exists)
            let delete = calendar.buttons["delete-event-button"]
            XCTAssertTrue(delete.exists && delete.isHittable)
            delete.tap()
            autonomyCaptureTree(calendar, "USB authorized B1005 only deletion confirmation")
        case "calendar-confirm-owned-delete":
            XCTAssertEqual(marker, "Task38 USB B1005")
            let calendar = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
            XCTAssertTrue(calendar.staticTexts[marker + " · 장소: 테스트룸"].exists)
            let confirmations = calendar.sheets.buttons.matching(identifier: "delete-alert-button")
            XCTAssertEqual(confirmations.count, 2, "Observed nested native buttons share one confirmation frame")
            let confirm = confirmations.firstMatch
            XCTAssertEqual(confirmations.element(boundBy: 1).frame, confirm.frame)
            XCTAssertEqual(confirm.label, "이벤트 삭제")
            XCTAssertTrue(confirm.isHittable)
            confirm.tap(); Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(calendar.staticTexts[marker + " · 장소: 테스트룸"].exists)
            XCTAssertEqual(calendar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", marker)).count, 0)
            autonomyCaptureTree(calendar, "USB authorized B1005 Calendar copy removed from observed day")
        case "inspect-owned-schedule":
            let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
            app.launchArguments = []; app.launch()
            XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
            let day = app.buttons["10월 7일 수요일"]
            XCTAssertTrue(day.waitForExistence(timeout: 8)); day.tap()
            let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "schedule-original-", marker)).firstMatch
            reveal(original, in: app); original.tap()
            XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 8))
            autonomyCaptureTree(app, "USB authorized new schedule detail " + marker)
        default:
            XCTFail("Unknown authorized fixture step")
        }
        print("[Task38 authorized fixture] marker=\(marker) step=\(step) epoch=\(Date().timeIntervalSince1970)")
    }

    func testUSBAuthorizedTwoHourRealCaptureAndTouch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 7800
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        let start = Date()
        var captureCount = 0, cycles = 0
        var nextCapture: TimeInterval = 0
        var nextTouch: TimeInterval = 0
        var maximumCycle: TimeInterval = 0
        let letters = Array("ABCDEFGHIJKL").map(String.init)
        print("[Task38 real two-hour] START epoch=\(start.timeIntervalSince1970) duration=7200 nativeCaptureInterval=600 touchInterval=30")
        while Date().timeIntervalSince(start) < 7200 {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= nextCapture && captureCount < letters.count {
                let marker = "Task38 USB R1005 " + letters[captureCount]
                let batchStart = Date()
                notes.activate(); Thread.sleep(forTimeInterval: 1)
                let compose = notes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "작성", "새로운 메모")).firstMatch
                XCTAssertTrue(compose.waitForExistence(timeout: 5) && compose.isHittable)
                compose.tap()
                let field = notes.textViews.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 8))
                let initial = field.value as? String ?? ""
                XCTAssertTrue(initial.isEmpty || initial == "메모")
                field.tap(); field.typeText(marker + "\n2026년 10월 8일 오후 4시\n장소: 테스트룸")
                XCTAssertTrue((field.value as? String ?? "").contains(marker))
                if notes.buttons["완료"].exists { notes.buttons["완료"].tap() }
                let settings = authorizedCaptureSettings()
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                setSwitch(settings.switches["AssistiveTouch"], to: true)
                print("[Task38 real two-hour] CAPTURE_CONTROL_ON marker=\(marker)")
                notes.activate(); Thread.sleep(forTimeInterval: 1.5)
                XCTAssertTrue((field.value as? String ?? "").contains(marker))
                XCTAssertEqual(board.frame, CGRect(x: 0, y: 0, width: 428, height: 926))
                for point in [(0.725, 0.956), (0.70, 0.72), (0.62, 0.85), (0.705, 0.655)] {
                    board.coordinate(withNormalizedOffset: CGVector(dx: point.0, dy: point.1)).tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
                Thread.sleep(forTimeInterval: 2)
                attach(notes, name: "USB two-hour native captured new note " + marker)
                settings.activate(); Thread.sleep(forTimeInterval: 1)
                setSwitch(settings.switches["AssistiveTouch"], to: false)
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                print("[Task38 real two-hour] CAPTURE_CONTROL_OFF marker=\(marker)")
                app.activate()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
                let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
                XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "candidate-image-", "원본 스크린샷, " + marker + " ·"))
                XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 20))
                XCTAssertEqual(row.count, 1)
                print("[Task38 real two-hour] ANALYZED marker=\(marker) candidate=\(row.firstMatch.identifier) label=\(row.firstMatch.label) batchSeconds=\(Date().timeIntervalSince(batchStart)) elapsed=\(Date().timeIntervalSince(start))")
                // Newly produced candidate IDs/source IDs are recorded; existing candidates are never edited.
                attach(app, name: "USB two-hour actual new candidate batch " + marker)
                app.navigationBars["후보"].buttons["홈"].tap()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
                captureCount += 1; nextCapture += 600
            }
            if Date().timeIntervalSince(start) >= nextTouch {
                let cycle = Date()
                XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 8))
                app.buttons["설정"].tap()
                XCTAssertTrue(app.buttons["완료"].waitForExistence(timeout: 8))
                app.buttons["완료"].tap()
                let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
                XCTAssertTrue(review.waitForExistence(timeout: 8)); review.tap()
                XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
                app.navigationBars["후보"].buttons["홈"].tap()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
                let seconds = Date().timeIntervalSince(cycle)
                maximumCycle = max(maximumCycle, seconds); cycles += 1
                print("[Task38 real two-hour] TOUCH cycles=\(cycles) captures=\(captureCount) elapsed=\(Date().timeIntervalSince(start)) cycleSeconds=\(seconds) maximumCycleSeconds=\(maximumCycle)")
                nextTouch = Date().timeIntervalSince(start) + 30
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(captureCount, 12)
        XCTAssertGreaterThan(cycles, 100)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 7200)
        autonomyCaptureTree(app, "USB two-hour actual final Home with approved new inputs")
        print("[Task38 real two-hour] COMPLETE elapsed=\(Date().timeIntervalSince(start)) newNativeCaptures=\(captureCount) touchCycles=\(cycles) maximumCycleSeconds=\(maximumCycle); timingsIncludeXCTest=true noRemoteCloudInput=true")
    }

    func testUSBAuthorizedRemainingRealCaptureAndTouch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 3300
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        let start = Date()
        var captureCount = 0, cycles = 0
        var nextCapture: TimeInterval = 0
        var nextTouch: TimeInterval = 0
        var maximumCycle: TimeInterval = 0
        let letters = Array("JKL").map(String.init)
        print("[Task38 real continuation] START epoch=\(start.timeIntervalSince1970) duration=2700 nativeCaptureInterval=900 touchInterval=30")
        while Date().timeIntervalSince(start) < 2700 {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= nextCapture && captureCount < letters.count {
                let marker = "Task38 USB R1005 " + letters[captureCount]
                let batchStart = Date()
                notes.activate(); Thread.sleep(forTimeInterval: 1)
                let compose = notes.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "작성", "새로운 메모")).firstMatch
                XCTAssertTrue(compose.waitForExistence(timeout: 5) && compose.isHittable)
                compose.tap()
                let field = notes.textViews.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 8))
                let initial = field.value as? String ?? ""
                XCTAssertTrue(initial.isEmpty || initial == "메모")
                field.tap(); field.typeText(marker + "\n2026년 10월 8일 오후 4시\n장소: 테스트룸")
                XCTAssertTrue((field.value as? String ?? "").contains(marker))
                if notes.buttons["완료"].exists { notes.buttons["완료"].tap() }
                let settings = authorizedCaptureSettings()
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                setSwitch(settings.switches["AssistiveTouch"], to: true)
                print("[Task38 real continuation] CAPTURE_CONTROL_ON marker=\(marker)")
                notes.activate(); Thread.sleep(forTimeInterval: 1.5)
                XCTAssertTrue((field.value as? String ?? "").contains(marker))
                XCTAssertEqual(board.frame, CGRect(x: 0, y: 0, width: 428, height: 926))
                for point in [(0.725, 0.956), (0.70, 0.72), (0.62, 0.85), (0.705, 0.655)] {
                    board.coordinate(withNormalizedOffset: CGVector(dx: point.0, dy: point.1)).tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
                Thread.sleep(forTimeInterval: 2)
                attach(notes, name: "USB remaining segment native captured new note " + marker)
                settings.activate(); Thread.sleep(forTimeInterval: 1)
                setSwitch(settings.switches["AssistiveTouch"], to: false)
                XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
                print("[Task38 real continuation] CAPTURE_CONTROL_OFF marker=\(marker)")
                app.activate()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
                let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
                XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "candidate-image-", "원본 스크린샷, " + marker + " ·"))
                XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 20))
                XCTAssertEqual(row.count, 1)
                print("[Task38 real continuation] ANALYZED marker=\(marker) candidate=\(row.firstMatch.identifier) label=\(row.firstMatch.label) batchSeconds=\(Date().timeIntervalSince(batchStart)) elapsed=\(Date().timeIntervalSince(start))")
                // Newly produced candidate IDs/source IDs are recorded; existing candidates are never edited.
                attach(app, name: "USB remaining segment actual new candidate batch " + marker)
                app.navigationBars["후보"].buttons["홈"].tap()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
                captureCount += 1; nextCapture += 900
            }
            if Date().timeIntervalSince(start) >= nextTouch {
                let cycle = Date()
                XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 8))
                app.buttons["설정"].tap()
                XCTAssertTrue(app.buttons["완료"].waitForExistence(timeout: 8))
                app.buttons["완료"].tap()
                let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
                XCTAssertTrue(review.waitForExistence(timeout: 8)); review.tap()
                XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
                app.navigationBars["후보"].buttons["홈"].tap()
                XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
                let seconds = Date().timeIntervalSince(cycle)
                maximumCycle = max(maximumCycle, seconds); cycles += 1
                print("[Task38 real continuation] TOUCH cycles=\(cycles) captures=\(captureCount) elapsed=\(Date().timeIntervalSince(start)) cycleSeconds=\(seconds) maximumCycleSeconds=\(maximumCycle)")
                nextTouch = Date().timeIntervalSince(start) + 30
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(captureCount, 3)
        XCTAssertGreaterThan(cycles, 40)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 2700)
        autonomyCaptureTree(app, "USB remaining segment actual final Home with approved new inputs")
        print("[Task38 real continuation] COMPLETE elapsed=\(Date().timeIntervalSince(start)) newNativeCaptures=\(captureCount) touchCycles=\(cycles) maximumCycleSeconds=\(maximumCycle); timingsIncludeXCTest=true noRemoteCloudInput=true")
    }

    private func authorizedCaptureSettings() -> XCUIApplication {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        Thread.sleep(forTimeInterval: 1)
        if settings.switches["AssistiveTouch"].exists { return settings }
        openSystemRoot(settings)
        Thread.sleep(forTimeInterval: 1)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        for _ in 0..<4 {
            if accessibility.exists && accessibility.isHittable && settings.frame.insetBy(dx: 0, dy: 110).contains(accessibility.frame) { break }
            settings.swipeDown()
        }
        XCTAssertTrue(accessibility.exists && settings.frame.insetBy(dx: 0, dy: 110).contains(accessibility.frame))
        accessibility.tap()
        XCTAssertTrue(settings.navigationBars["손쉬운 사용"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        let touch = settings.staticTexts["터치"]
        for _ in 0..<3 {
            if touch.exists && touch.isHittable && settings.frame.insetBy(dx: 0, dy: 100).contains(touch.frame) { break }
            settings.swipeUp()
        }
        XCTAssertTrue(touch.exists && settings.frame.insetBy(dx: 0, dy: 100).contains(touch.frame))
        touch.tap()
        XCTAssertTrue(settings.navigationBars["터치"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        settings.staticTexts["AssistiveTouch"].tap()
        XCTAssertTrue(settings.switches["AssistiveTouch"].waitForExistence(timeout: 5))
        return settings
    }

    func testUSBAutonomyCommitObservedJapaneseLanguageRemoval() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars["언어 및 지역"].exists)
        XCTAssertFalse(settings.sheets.firstMatch.exists)
        XCTAssertTrue(settings.cells["ko-KR"].exists && settings.cells["ja-KR"].exists)
        XCTAssertFalse(settings.cells["en-KR"].exists)
        let remove = settings.buttons["삭제"]
        XCTAssertEqual(settings.buttons.matching(identifier: "삭제").count, 1)
        XCTAssertTrue(settings.frame.contains(remove.frame))
        remove.tap()
        autonomyCaptureTree(settings, "USB autonomy observed Japanese-only language removal result")
    }

    func testUSBAutonomyRootSnapshotDirectBanner() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 900
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launchArguments = []; app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "US/Pacific")!
        let target = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(240))
        XCTAssertEqual(target.year, 2026); XCTAssertEqual(target.month, 10); XCTAssertEqual(target.day, 5)
        let fire = calendar.date(from: target)!
        app.buttons["편집"].tap()
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        XCTAssertEqual(app.switches["당일 알림"].value as? String, "1")
        selectTestTime(hour: target.hour!, minute: target.minute!, in: app)
        var changed = true
        defer { if changed { restoreOriginalTestSchedule(app) } }
        saveTestSchedule(app)
        let expected = "시간, \(target.hour! < 12 ? "오전" : "오후") \(target.hour! % 12 == 0 ? 12 : target.hour! % 12):\(String(format: "%02d", target.minute!))"
        guard app.staticTexts[expected].waitForExistence(timeout: 5) else {
            autonomyCaptureTree(app, "USB autonomy unexpected saved reminder display before explicit restoration")
            restoreOriginalTestSchedule(app); changed = false
            XCTFail("Saved reminder must match actual target before waiting for banner")
            return
        }
        autonomyCaptureTree(app, "USB autonomy real planner temporary October5 reminder")
        app.terminate(); XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = board.coordinate(withNormalizedOffset: .zero)
        let viewport = board.frame
        print("[Task38 autonomy direct banner] target=\(fire.timeIntervalSince1970) time=\(expected) actual planner; no typed BannerNotification/title queries or Center fallback")
        var logAt = Date()
        while Date() < fire.addingTimeInterval(-1) {
            if Date() >= logAt { print("[Task38 autonomy direct banner] waitSeconds=\(fire.timeIntervalSinceNow)"); logAt = Date().addingTimeInterval(30) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Read the root snapshot instead of constructing a query for the
        // unsupported BannerNotification element that failed in old runs.
        let pattern = #"\{\{([0-9.]+), ([0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        var observed = false
        var reached = false
        while Date() < fire.addingTimeInterval(12) {
            let tree = board.debugDescription
            let lines = tree.components(separatedBy: "\n")
            if let index = lines.firstIndex(where: { $0.contains("NotificationShortLookView") }),
               lines[index...min(index + 16, lines.count - 1)].joined(separator: "\n").contains("Task38 테스트"),
               let match = regex.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])) {
                let values = (1...4).map { Double((lines[index] as NSString).substring(with: match.range(at: $0)))! }
                let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                if viewport.contains(frame), frame.minY < 200, frame.width > 200, frame.height > 40 {
                    observed = true
                    let evidence = XCTAttachment(string: tree); evidence.name = "USB autonomy actual direct banner root snapshot"; evidence.lifetime = .keepAlways; add(evidence)
                    let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screen.name = "USB autonomy actual direct banner before coordinate touch"; screen.lifetime = .keepAlways; add(screen)
                    print("[Task38 autonomy direct banner] actual approved ShortLook frame=\(frame)")
                    origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    reached = app.wait(for: .runningForeground, timeout: 15) && app.navigationBars["일정"].waitForExistence(timeout: 15) && app.staticTexts[expected].exists
                    if reached { autonomyCaptureTree(app, "USB autonomy actual direct banner cold tap matching detail") }
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        restoreOriginalTestSchedule(app); changed = false
        XCTAssertTrue(observed, "Actual top banner required; no Center substitution")
        XCTAssertTrue(reached, "Actual banner touch must cold launch matching detail")
    }

    func testUSBAutonomyConfirmPreferredLanguageRemoval() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars["언어 및 지역"].exists)
        XCTAssertTrue(settings.cells["ko-KR"].exists)
        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["이 설정을 적용하면 iPhone이 재시동됩니다."].exists)
        autonomyCaptureTree(settings, "USB autonomy observed Korean preferred-language removal confirmation")
        sheet.buttons["계속"].tap()
        print("[Task38 autonomy cleanup] exact observed Continue issued; verify after system UI transition separately")
    }

    func testUSBAutonomyRemoveRemainingTestLanguage() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars["언어 및 지역"].exists)
        XCTAssertFalse(settings.sheets.firstMatch.exists)
        XCTAssertFalse(settings.cells["en-KR"].exists)
        XCTAssertTrue(settings.cells["ko-KR"].exists)
        let japanese = settings.cells["ja-KR"]
        XCTAssertTrue(japanese.exists && settings.frame.contains(japanese.frame))
        // The observed full swipe itself requests removal and opens Continue;
        // the Delete button underneath that sheet must not be tapped.
        japanese.swipeLeft()
        XCTAssertTrue(settings.sheets.firstMatch.staticTexts["이 설정을 적용하면 iPhone이 재시동됩니다."].waitForExistence(timeout: 5))
        autonomyCaptureTree(settings, "USB autonomy Japanese removal pending actual native Continue")
    }

    func testUSBAutonomyLanguageBaseline() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars["언어 및 지역"].exists)
        XCTAssertFalse(settings.sheets.firstMatch.exists)
        XCTAssertTrue(settings.cells["ko-KR"].exists)
        XCTAssertFalse(settings.cells["en-KR"].exists)
        XCTAssertFalse(settings.cells["ja-KR"].exists)
        XCTAssertTrue(settings.buttons["LOCALE"].label.contains("대한민국"))
        autonomyCaptureTree(settings, "USB autonomy Korean-only language baseline restored")
    }

    func testUSBAutonomyLanguagePicker() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let addLanguage = settings.buttons.matching(identifier: "ADD_PREFERRED_LANGUAGE")
        XCTAssertEqual(addLanguage.count, 1)
        addLanguage.firstMatch.tap()
        autonomyCaptureTree(settings, "USB autonomy actual system add language picker")
    }

    func testUSBAutonomySelectLanguage() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let label = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE_LABEL", default: ""]
        guard ["English", "日本語"].contains(label) else { throw XCTSkip("Exact test language opt-in required") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        // The observed native picker uses StaticText rows, not Buttons.
        let option = settings.staticTexts.matching(NSPredicate(format: "label == %@", label))
        XCTAssertEqual(option.count, 1)
        XCTAssertTrue(settings.frame.contains(option.firstMatch.frame))
        option.firstMatch.tap()
        autonomyCaptureTree(settings, "USB autonomy exact \(label) system language confirmation before applying")
    }

    func testUSBAutonomyConfirmLanguageAndCaptureWidgets() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let code = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE", default: ""]
        let confirmLabel = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE_CONFIRM", default: ""]
        guard ["en", "ja"].contains(code), !confirmLabel.isEmpty else { throw XCTSkip("Exact observed language confirmation opt-in required") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let settingsButton = settings.buttons[confirmLabel]
        let boardButton = board.buttons[confirmLabel]
        if settingsButton.exists {
            XCTAssertTrue(settings.frame.contains(settingsButton.frame))
            settingsButton.tap()
        } else {
            XCTAssertTrue(boardButton.exists && board.frame.contains(boardButton.frame))
            boardButton.tap()
        }
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.navigationBars[code == "en" ? "Home" : "ホーム"].waitForExistence(timeout: 60))
        app.terminate()
        XCUIDevice.shared.press(.home)
        let widgets = board.otherElements.matching(identifier: "SnapSchedule")
        if widgets.count < 2 { board.swipeLeft() }
        let visible = widgets.allElementsBoundByIndex.filter { board.frame.contains($0.frame) && $0.frame.width > 150 && $0.frame.height > 150 }
        XCTAssertEqual(Set(visible.map { String(describing: $0.frame) }).count, 2)
        XCTAssertTrue(visible.allSatisfy { $0.staticTexts["Task38 테스트"].exists })
        autonomyCaptureTree(board, "USB autonomy actual small medium Widgets system language \(code)")
        print("[Task38 autonomy Widget language] system=\(code) installedAppNoLaunchOverride=true actualWidgets2; semantic localized text still inspect screenshot")
    }

    func testUSBAutonomyRestoreKoreanPreferredOrder() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let currentLanguage = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE_LABEL", default: ""]
        guard ["English", "日本語"].contains(currentLanguage) else { throw XCTSkip("Exact current preferred test language required") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let handleLabel = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_KOREAN_REORDER_LABEL", default: ""]
        guard handleLabel.contains("한국어") else { throw XCTSkip("Observed Korean reorder handle label required") }
        let handle = settings.buttons[handleLabel]
        let top = settings.staticTexts[currentLanguage]
        XCTAssertTrue(handle.exists && top.exists)
        XCTAssertTrue(settings.frame.contains(handle.frame) && settings.frame.contains(top.frame))
        let destination = settings.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: handle.frame.midX, dy: top.frame.midY))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: destination)
        autonomyCaptureTree(settings, "USB autonomy Korean preferred-order restoration confirmation")
    }

    // The language switch restarts system UI and can invalidate its XCTest
    // session. Capture in a fresh session without applying the language again.
    func testUSBAutonomyCaptureCurrentWidgets() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let code = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE", default: ""]
        guard ["en", "ja"].contains(code) else { throw XCTSkip("Exact current OS language required") }
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.navigationBars[code == "en" ? "Home" : "ホーム"].waitForExistence(timeout: 30))
        app.terminate()
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let widgets = board.otherElements.matching(identifier: "SnapSchedule")
        if widgets.count < 2 { board.swipeLeft() }
        let visible = widgets.allElementsBoundByIndex.filter { board.frame.contains($0.frame) && $0.frame.width > 150 && $0.frame.height > 150 }
        XCTAssertEqual(Set(visible.map { String(describing: $0.frame) }).count, 2)
        autonomyCaptureTree(board, "USB autonomy current actual \(code) small medium Widget language")
        let groups = Dictionary(grouping: visible, by: { String(describing: $0.frame) })
        for group in groups.values {
            let small = group[0].frame.width < 250
            let heading = code == "en" ? (small ? "Next schedule" : "Upcoming schedules") : (small ? "次の予定" : "今後の予定")
            // Widget AX may coalesce title/date into a link or wrapper rather
            // than separate StaticText children. Require content per real size.
            XCTAssertTrue(group.contains { element in
                let content = element.debugDescription
                return content.contains("Task38 테스트") && content.contains(heading)
            })
        }
        print("[Task38 autonomy Widget language] system=\(code) noAppLaunchLanguageOverride widgets2 bothFamilyLocalizedHeadings")
    }

    func testUSBAutonomyApplyObservedSystemLanguage() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let code = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE", default: ""]
        let label = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE_CONFIRM", default: ""]
        guard ["en", "ja"].contains(code), !label.isEmpty else { throw XCTSkip("Exact observed test language confirmation required") }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let confirm = settings.sheets.firstMatch.buttons[label]
        XCTAssertTrue(confirm.exists && settings.frame.contains(confirm.frame))
        autonomyCaptureTree(settings, "USB autonomy observed \(code) system language confirmation")
        confirm.tap()
        print("[Task38 autonomy language action] requested=\(code) exactObservedConfirmationEventIssued; OS restart/application verified only in separate next session")
    }

    func testUSBAutonomyApplyObservedKoreanConfirmation() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let label = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_LANGUAGE_CONFIRM", default: ""]
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        if label == "続ける" {
            XCTAssertTrue(settings.sheets.staticTexts["この設定を適用するとiPhoneが再起動します。"].exists)
            XCTAssertTrue(settings.cells["ko-KR"].exists && settings.cells["ja-KR"].exists)
            XCTAssertLessThan(settings.cells["ko-KR"].frame.minY, settings.cells["ja-KR"].frame.minY)
        } else if !(label.contains("Korean") || label.contains("한국어") || label.contains("韓国語")) {
            throw XCTSkip("Exact observed Korean confirmation required")
        }
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if settings.buttons[label].exists { settings.buttons[label].tap() }
        else { XCTAssertTrue(board.buttons[label].exists); board.buttons[label].tap() }
        print("[Task38 autonomy Korean restore] observed confirmation event issued; verify actual Korean and preferred-language cleanup in separate next session")
    }

    func testUSBAutonomyRemoveAddedPreferredLanguages() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars["언어 및 지역"].exists)
        for label in ["English", "日本語"] {
            let row = settings.cells.containing(.staticText, identifier: label).firstMatch
            if !row.exists { continue }
            XCTAssertTrue(settings.frame.contains(row.frame))
            row.swipeLeft()
            let remove = settings.buttons["삭제"]
            XCTAssertTrue(remove.exists && settings.frame.contains(remove.frame))
            remove.tap()
        }
        XCTAssertFalse(settings.staticTexts["English"].exists)
        XCTAssertFalse(settings.staticTexts["日本語"].exists)
        XCTAssertTrue(settings.staticTexts["한국어"].exists)
        XCTAssertTrue(settings.buttons["LOCALE"].label.contains("대한민국"))
        autonomyCaptureTree(settings, "USB autonomy original Korean-only preferred languages region baseline restored")
    }

    func testUSBAutonomyCurrentNativeControls() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let bundle = ProcessInfo.processInfo.environment["TASK38_AUTONOMY_NATIVE_BUNDLE", default: ""]
        guard ["com.apple.Preferences", "com.apple.mobileslideshow", "com.apple.mobilecal"].contains(bundle) else { throw XCTSkip("Explicit native observation opt-in required") }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.activate()
        autonomyCaptureTree(app, "USB autonomy actual native foreground controls \(bundle)")
    }

    // Fresh observed portrait Collections exposes SearchTab. Observe a new
    // selection route; never reuse the failed context-menu deletion path.
    func testUSBResidualObservedSearchSelectionRoute() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertEqual(photos.sheets.count, 0)
        let search = photos.buttons["SearchTab"]
        XCTAssertTrue(search.exists && search.isHittable && photos.frame.contains(search.frame))
        search.tap()
        let input = photos.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        if input.value as? String != "Task38" {
            XCTAssertTrue((input.value as? String ?? "").isEmpty, "Do not append to an unrelated search")
            input.tap()
            photos.typeText("Task38\n")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertTrue(source.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(source.count, 1)
        XCTAssertTrue(photos.frame.insetBy(dx: -1, dy: -1).contains(source.firstMatch.frame))
        autonomyCaptureTree(photos, "USB residual fresh approved-source search selection controls; no mutation")
    }

    func testUSBResidualSelectOnlyApprovedSearchResult() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertEqual(photos.sheets.count, 0)
        XCTAssertEqual(photos.textViews.firstMatch.value as? String, "Task38")
        XCTAssertTrue(photos.staticTexts["1개의 결과"].exists)
        let select = photos.buttons["선택"]
        XCTAssertTrue(select.exists && select.isHittable && photos.frame.contains(select.frame))
        select.tap()
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertEqual(source.count, 1)
        XCTAssertTrue(source.firstMatch.isHittable && photos.frame.insetBy(dx: -1, dy: -1).contains(source.firstMatch.frame))
        source.firstMatch.tap()
        autonomyCaptureTree(photos, "USB residual selection-mode approved result only; before any delete")
    }

    func testUSBResidualSelectObservedSingleResultSet() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertEqual(photos.sheets.count, 0)
        XCTAssertTrue(photos.staticTexts["1개의 결과"].exists)
        let images = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertEqual(images.count, 1, "Select-all is permitted only for this observed one-result query")
        XCTAssertEqual(images.firstMatch.label, "스크린샷, Screenshot, 10월 04일, 오전 3:15")
        XCTAssertTrue(photos.frame.insetBy(dx: -1, dy: -1).contains(images.firstMatch.frame))
        let oneResult = photos.buttons["전체 선택"]
        XCTAssertTrue(oneResult.isHittable && photos.frame.contains(oneResult.frame))
        oneResult.tap()
        autonomyCaptureTree(photos, "USB residual exact single-result selected via visible selection button; no delete")
    }

    func testUSBResidualDeleteObservedSelectedSingleSource() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertEqual(photos.sheets.count, 0)
        XCTAssertEqual(photos.staticTexts["PXBarItemIdentifierSelectModeCaption"].label, "1장의 사진이 선택됨")
        let images = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.firstMatch.label, "스크린샷, Screenshot, 10월 04일, 오전 3:15")
        XCTAssertTrue(images.firstMatch.isSelected)
        let remove = photos.buttons["삭제"]
        XCTAssertTrue(remove.isHittable && photos.frame.contains(remove.frame))
        remove.tap()
        autonomyCaptureTree(photos, "USB residual selection-mode one-source delete confirmation")
        XCTAssertEqual(photos.sheets.count, 1)
        let confirm = photos.sheets.firstMatch.buttons["사진 삭제"]
        XCTAssertTrue(confirm.isHittable && photos.frame.contains(confirm.frame))
        confirm.tap()
        autonomyCaptureTree(photos, "USB residual selection-mode deletion issued; actual post-action state")
        let absent = NSPredicate { _, _ in !images.firstMatch.exists }
        _ = expectation(for: absent, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        autonomyCaptureTree(app, "USB residual actual unavailable source with preserved candidates2")
    }

    func testUSBResidualAcknowledgeObservedDeletionNotice() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        let notice = photos.alerts["삭제된 사진은 최근 삭제된 앨범으로 이동됨"]
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(notice.buttons["확인"].isHittable)
        notice.buttons["확인"].tap()
        autonomyCaptureTree(photos, "USB residual after acknowledging actual Recently Deleted notice")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        autonomyCaptureTree(app, "USB residual after deletion notice approved source unavailable candidates2")
    }

    func testUSBResidualOpenObservedRecoveryShelf() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        let close = photos.buttons["닫기"]
        XCTAssertTrue(close.isHittable && photos.frame.contains(close.frame))
        close.tap()
        let collections = photos.buttons["CollectionsTab"]
        XCTAssertTrue(collections.isHittable)
        collections.tap()
        let shelf = photos.scrollViews["bookmark-shelf-scrollView"]
        XCTAssertTrue(shelf.exists && photos.frame.contains(shelf.frame))
        let recent = shelf.buttons.matching(NSPredicate(format: "label == %@", "최근 삭제된 항목")).firstMatch
        XCTAssertTrue(recent.exists)
        if !photos.frame.contains(recent.frame) { shelf.swipeLeft() }
        XCTAssertTrue(photos.frame.contains(recent.frame) && recent.isHittable)
        recent.tap()
        autonomyCaptureTree(photos, "USB residual actual Recently Deleted foreground before authentication")
        let view = photos.buttons["앨범 보기"]
        if view.exists && view.isHittable { view.tap() }
        autonomyCaptureTree(photos, "USB residual actual recovery authentication or authenticated album; no photo selected")
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        autonomyCaptureTree(system, "USB residual actual OS authentication gate observation")
    }

    func testUSBResidualContinueObservedRecoveryShelfEdge() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertTrue(photos.navigationBars["모음"].exists)
        let shelf = photos.scrollViews["bookmark-shelf-scrollView"]
        XCTAssertTrue(shelf.exists && photos.frame.contains(shelf.frame))
        let recent = shelf.buttons.matching(NSPredicate(format: "label == %@", "최근 삭제된 항목")).firstMatch
        XCTAssertTrue(recent.exists)
        XCTAssertTrue(recent.frame.minX >= 400 && recent.frame.minX <= 430,
                      "Continue only the freshly observed x416 shelf edge, no blind scroll loop")
        shelf.swipeLeft()
        XCTAssertTrue(photos.frame.contains(recent.frame) && recent.isHittable)
        recent.tap()
        autonomyCaptureTree(photos, "USB residual actual Recently Deleted before authentication")
        let view = photos.buttons["앨범 보기"]
        if view.exists && view.isHittable { view.tap() }
        autonomyCaptureTree(photos, "USB residual actual Recently Deleted authentication boundary")
        autonomyCaptureTree(XCUIApplication(bundleIdentifier: "com.apple.springboard"), "USB residual OS recovery authentication boundary")
    }

    func testUSBResidualRecoverAuthenticatedVisibleApprovedSource() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertFalse(photos.buttons["앨범 보기"].exists)
        XCTAssertTrue(photos.staticTexts.matching(identifier: "collectionTitle").allElementsBoundByIndex.contains { $0.label == "최근 삭제된 항목" })
        let matches = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15")).allElementsBoundByIndex
        // Authenticated Photos paging exposes duplicate wrappers for the same
        // visible top-left source. Require every match to be that exact frame.
        XCTAssertFalse(matches.isEmpty)
        for source in matches {
            XCTAssertTrue(abs(source.frame.minX) < 1 && abs(source.frame.minY - 175.3) < 2)
            XCTAssertTrue(abs(source.frame.width - 141.6) < 2 && abs(source.frame.height - 141.7) < 2)
            XCTAssertTrue(photos.frame.insetBy(dx: -1, dy: -1).contains(source.frame))
        }
        let frame = try XCTUnwrap(matches.first).frame
        photos.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        autonomyCaptureTree(photos, "USB residual authenticated exact deleted source opened before single recovery")
        let recover = photos.buttons.matching(NSPredicate(format: "label == %@", "복구"))
        XCTAssertTrue(recover.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(recover.count, 1)
        XCTAssertTrue(recover.firstMatch.isHittable && photos.frame.contains(recover.firstMatch.frame))
        recover.firstMatch.tap()
        autonomyCaptureTree(photos, "USB residual approved one-photo recovery confirmation")
        let confirm = photos.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "사진 복구", "1장의 사진 복구"))
        XCTAssertEqual(confirm.count, 1, "Never Recover All")
        XCTAssertTrue(confirm.firstMatch.isHittable && photos.frame.contains(confirm.firstMatch.frame))
        confirm.firstMatch.tap()
        autonomyCaptureTree(photos, "USB residual after exact one-photo recovery")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["스크린샷을 사용할 수 없음"].exists)
        autonomyCaptureTree(app, "USB residual recovered approved original in fresh process candidates2 preserved")
    }

    private func autonomyCaptureTree(_ app: XCUIApplication, _ name: String) {
        attach(app, name: name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testUSBAutonomyContextDeleteConfirmation() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        // This is the observed one-source context preview, not the old toolbar.
        let preview = photos.otherElements.matching(NSPredicate(format: "label == %@", "스크린샷, Screenshot, 10월 04일, 오전 3:15")).firstMatch
        XCTAssertTrue(preview.exists && photos.frame.insetBy(dx: -1, dy: -1).contains(preview.frame))
        let remove = photos.buttons.matching(NSPredicate(format: "label == %@", "삭제"))
        XCTAssertEqual(remove.count, 1)
        XCTAssertTrue(photos.frame.contains(remove.firstMatch.frame))
        remove.firstMatch.tap()
        attach(photos, name: "USB autonomy context one-photo deletion confirmation before commit")
        let tree = XCTAttachment(string: photos.debugDescription)
        tree.name = "USB autonomy actual context deletion confirmation tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testUSBAutonomyCommitObservedDelete() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        // Require the actual frontmost native sheet rather than a root query
        // matching a button on a hidden Photos paging view.
        XCTAssertEqual(photos.sheets.count, 1)
        let confirm = photos.sheets.firstMatch.buttons["사진 삭제"]
        XCTAssertTrue(confirm.exists && photos.frame.contains(confirm.frame))
        attach(photos, name: "USB autonomy observed frontmost one-photo sheet before approved deletion")
        confirm.tap()
        let result = XCTAttachment(string: photos.debugDescription)
        result.name = "USB autonomy Photos state immediately after exact sheet deletion"
        result.lifetime = .keepAlways
        add(result)
        attach(photos, name: "USB autonomy Photos state after approved one-source deletion")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        attach(app, name: "USB autonomy deleted approved source unavailable in new process with candidates2")
        print("[Task38 autonomy deletion] exact native sheet source unavailable candidates2 newProcess; narrow SDK absence and exact recovery still required")
    }

    // Native foreground Search is already visible; do not require a SearchTab
    // from the library root or use hidden results behind a paging overlay.
    func testUSBAutonomyVisibleSourceMenu() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        let tree = XCTAttachment(string: photos.debugDescription)
        tree.name = "USB autonomy actual Photos foreground tree before menu"
        tree.lifetime = .keepAlways
        add(tree)
        attach(photos, name: "USB autonomy actual Search foreground before approved menu")
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertFalse(photos.buttons["앨범 보기"].exists)
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertEqual(source.count, 1)
        let frame = source.firstMatch.frame
        print("[Task38 autonomy approved source menu] actualFrame=\(photos.frame) sourceFrame=\(frame) sourceCount1 noPhotoMutation")
        // The native visible grid reports its left edge as a tiny negative
        // floating-point value (-0.0 in AX). Keep full viewport protection with
        // a one-point rounding margin; do not accept offscreen paging results.
        XCTAssertTrue(photos.frame.insetBy(dx: -1, dy: -1).contains(frame) && frame.width > 30 && frame.height > 30)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        attach(photos, name: "USB autonomy exact visible approved source context menu")
        let menu = XCTAttachment(string: photos.debugDescription)
        menu.name = "USB autonomy observed approved source context menu tree"
        menu.lifetime = .keepAlways
        add(menu)
    }

    // Read current orientation and the native per-app language controls before
    // choosing a language path. No permission, photo, calendar or store change.
    // Recorded preparation failures: notification Back -> global list; native
    // app preferences later exposed no Language button. Do not rerun unchanged.
    func testUSBResumedLanguageControls() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 15))
        print("[Task38 resumed actual frame] \(app.frame) orientation=\(XCUIDevice.shared.orientation.rawValue)")
        attach(app, name: "USB resumed actual Home orientation and preserved fixture")
        let settings = continuedSettingsRoot()
        let apps = settings.staticTexts["앱"]
        revealFromTop(apps, in: settings)
        apps.tap()
        let search = settings.searchFields.firstMatch
        if !search.exists { settings.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("SnapSchedule")
        // Known native Apps result is a Button with the bundle identifier;
        // the embedded StaticText was not a reliable control in prior runs.
        let entry = settings.buttons["com.example.SnapSchedule"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(settings.staticTexts["사진"].waitForExistence(timeout: 8))
        attach(settings, name: "USB resumed native SnapSchedule language controls")
        print("[Task38 resumed language] cells=" + settings.cells.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        print("[Task38 resumed language] buttons=" + settings.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let language = settings.buttons.matching(NSPredicate(format: "label CONTAINS %@", "언어")).firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 8))
        language.tap()
        attach(settings, name: "USB resumed actual native per app language choices")
        print("[Task38 resumed language choices] cells=" + settings.cells.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        print("[Task38 resumed language choices] buttons=" + settings.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
    }

    func testUSBResumedActualCandidateLanguages() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer { app.terminate(); app.launchArguments = []; app.launch() }
        for (code, home, review, gallery) in [("en", "Home", "Review candidates", "Candidates"), ("ja", "ホーム", "候補を確認", "候補")] {
            app.terminate()
            app.launchArguments = ["-AppleLanguages", "(\(code))", "-AppleLocale", code == "en" ? "en_US" : "ja_JP"]
            app.launch()
            XCTAssertTrue(app.navigationBars[home].waitForExistence(timeout: 20))
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", review)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            button.tap()
            XCTAssertTrue(app.navigationBars[gallery].waitForExistence(timeout: 8))
            XCTAssertEqual(residualCandidateImages(app).count, 2)
            attach(app, name: "USB resumed actual \(code) candidate gallery preserved two candidates")
            residualCandidateImages(app).firstMatch.tap()
            attach(app, name: "USB resumed actual \(code) candidate editor fields without edits")
            let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
            reveal(original, in: app)
            XCTAssertTrue(original.waitForExistence(timeout: 15))
            attach(app, name: "USB resumed actual \(code) candidate editor original")
            print("[Task38 resumed real language] app=\(code) candidates2 originalAvailable launchOverrideOnly noStoredEdits noWidgetLanguageClaim")
        }
    }

    func testUSBResumedSystemLanguageChoices() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        attach(settings, name: "USB resumed cold native Settings state before language route")
        XCTAssertTrue(settings.navigationBars["설정"].waitForExistence(timeout: 10))
        let general = settings.staticTexts["일반"]
        revealFromTop(general, in: settings)
        general.tap()
        let language = settings.staticTexts["언어 및 지역"]
        reveal(language, in: settings)
        language.tap()
        attach(settings, name: "USB resumed actual OS language region choices without change")
        print("[Task38 resumed system languages] buttons=" + settings.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        print("[Task38 resumed system languages] cells=" + settings.cells.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
    }

    // Recorded preparation failure: locked Photos paging overlay exposes ghost
    // Search AX results outside the viewport. Do not rerun unchanged.
    func testUSBResumedApprovedSourceContextMenu() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(photos.frame.width < photos.frame.height, "Observe portrait; do not guess a rotated grid")
        for _ in 0..<3 {
            if photos.buttons["SearchTab"].waitForExistence(timeout: 2) { break }
            let back = photos.buttons["PXBarItemIdentifierExplicitBack"]
            guard back.exists else {
                attach(photos, name: "USB resumed Photos route lacks observed explicit back; no deletion")
                throw XCTSkip("No observed exact Photos back control; no guessed touch")
            }
            back.tap()
        }
        XCTAssertTrue(photos.buttons["SearchTab"].waitForExistence(timeout: 8))
        photos.buttons["SearchTab"].tap()
        let input = photos.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        if input.value as? String != "Task38" {
            input.tap()
            photos.typeText("Task38\n")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertTrue(source.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(source.count, 1)
        let frame = source.firstMatch.frame
        XCTAssertTrue(photos.frame.contains(frame) && frame.width > 30 && frame.height > 30)
        print("[Task38 resumed approved source context] portrait=\(photos.frame) exactKnownResult=\(frame)")
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        attach(photos, name: "USB resumed approved exact source long press menu; no deletion")
        print("[Task38 resumed approved context controls] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        print("[Task38 resumed approved context controls] menus=" + photos.menuItems.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBResumedPhotosForegroundAuthenticationGate() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        attach(photos, name: "USB resumed actual Photos foreground auth gate; no other photo touched")
        print("[Task38 resumed Photos foreground] frame=\(photos.frame) albumGate=\(photos.buttons["앨범 보기"].exists)")
        if photos.buttons["앨범 보기"].exists {
            print("[Task38 resumed Photos] actual OS FaceID/passcode gate; no guessed hidden search touch")
            throw XCTSkip("User native authentication required for visible Recently Deleted gate")
        }
        throw XCTSkip("Observation only; no deletion or recovery validation performed")
    }

    // Residual scenes only: the previously verified Home/detail/editor cases
    // are not rerun. These cases never edit/register/dismiss a candidate.
    func testUSBContinuedCandidateWidgetLargestText() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
        settings.staticTexts["손쉬운 사용"].tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        settings.buttons["LARGER_TEXT"].tap()
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        XCTAssertEqual(slider.value as? String, "50%")
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "0")
        defer {
            settings.activate()
            setSwitch(settings.switches.firstMatch, to: false)
            slider.adjust(toNormalizedSliderPosition: 0.5)
            XCTAssertEqual(slider.value as? String, "50%")
            attach(settings, name: "USB continued largest text baseline OFF 50 restored")
        }
        setSwitch(settings.switches.firstMatch, to: true)
        slider.adjust(toNormalizedSliderPosition: 1)
        attach(settings, name: "USB continued actual largest OS text setting")
        inspectContinuedCandidateAndWidgets("largest OS text")
    }

    func testUSBContinuedCandidateWidgetContrast() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
        settings.staticTexts["손쉬운 사용"].tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        let contrast = settings.switches["대비 증가"]
        reveal(contrast, in: settings)
        XCTAssertEqual(contrast.value as? String, "0")
        defer {
            settings.activate()
            setSwitch(contrast, to: false)
            attach(settings, name: "USB continued contrast OFF restored")
        }
        setSwitch(contrast, to: true)
        attach(settings, name: "USB continued actual OS increased contrast setting")
        inspectContinuedCandidateAndWidgets("increased contrast")
    }

    func testUSBContinuedCandidateWidgetDark() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = continuedSettingsRoot()
        let display = settings.staticTexts["디스플레이 및 밝기"]
        revealFromTop(display, in: settings)
        display.tap()
        let light = settings.buttons["라이트 모드"]
        XCTAssertTrue(light.waitForExistence(timeout: 8))
        XCTAssertEqual(settings.switches["자동"].value as? String, "0")
        defer {
            settings.activate()
            light.tap()
            Thread.sleep(forTimeInterval: 1)
            attach(settings, name: "USB continued Light AutoOFF baseline restored")
        }
        settings.buttons["다크 모드"].tap()
        Thread.sleep(forTimeInterval: 1)
        attach(settings, name: "USB continued actual Dark AutoOFF OS setting")
        inspectContinuedCandidateAndWidgets("Dark")
    }

    func testUSBContinuedCandidateWidgetReduceMotion() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
        settings.staticTexts["손쉬운 사용"].tap()
        reveal(settings.staticTexts["동작"], in: settings)
        settings.staticTexts["동작"].tap()
        let reduce = settings.switches["동작 줄이기"]
        XCTAssertTrue(reduce.waitForExistence(timeout: 8))
        XCTAssertEqual(reduce.value as? String, "0")
        defer {
            settings.activate()
            setSwitch(reduce, to: false)
            attach(settings, name: "USB continued Reduce Motion OFF restored")
        }
        setSwitch(reduce, to: true)
        attach(settings, name: "USB continued actual Reduce Motion OS setting")
        inspectContinuedCandidateAndWidgets("Reduce Motion")
    }

    func testUSBContinuedDeletedSourceEditorBeforeRecovery() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB new process actual deleted source gallery with both candidates retained")
        residualCandidateImages(app).firstMatch.tap()
        let unavailable = app.staticTexts["스크린샷을 사용할 수 없음"]
        reveal(unavailable.firstMatch, in: app)
        XCTAssertTrue(unavailable.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch.exists)
        attach(app, name: "USB actual deleted approved original unavailable in candidate editor; no saved edits")
        print("[Task38 actual deleted editor] newProcess=true candidates2 sourceUnavailable=true noSavedEdits=true")
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB Recently Deleted OS authentication screen kept open for recovery")
    }

    func testUSBContinuedResumeAuthenticatedOneSourceRecovery() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(photos.navigationBars["최근 삭제된 항목"].waitForExistence(timeout: 8))
        guard !photos.buttons["앨범 보기"].exists else {
            throw XCTSkip("OS authentication still locked; no other photo touched")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        for _ in 0..<40 {
            if source.count == 1 && source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780 { break }
            photos.swipeUp(velocity: .fast)
        }
        XCTAssertEqual(source.count, 1)
        XCTAssertTrue(source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved deleted October4 0315 source before recovery")
        let recover = photos.buttons["복구"]
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        recover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB approved one-photo recovery confirmation")
        print("[Task38 actual recovery confirmation] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let confirm = photos.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "사진 복구", "1장의 사진 복구"))
        XCTAssertEqual(confirm.count, 1, "Only exact one-photo recovery confirmation; never Recover All")
        confirm.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB actual one source recovered and candidates2 retained in fresh process")
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["스크린샷을 사용할 수 없음"].exists)
        attach(app, name: "USB same actual deleted source restored in editor; candidate duplication absent")
        print("[Task38 actual recovery] one known photo restored; newProcess candidates2 originalAvailable noSavedEdits")
    }

    func testUSBContinuedRecoverFromObservedLandscapeBoundary() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(photos.frame.width < photos.frame.height)
        XCTAssertTrue(photos.staticTexts["최근 삭제된 항목"].exists)

        guard !photos.buttons["앨범 보기"].exists else {
            throw XCTSkip("OS authentication still locked; no other photo touched")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@", "PXGGridLayout-Info", "스크린샷", "10월 04일", "3:15"))
        for _ in 0..<15 {
            if source.count == 1 && source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780 { break }
            photos.swipeUp(velocity: .fast)
        }
        guard source.count == 1 else {
            attach(photos, name: "USB portrait recent album exact test source not located; no other photo touched")
            print("[Task38 portrait recovery] observed sourceCount=\(source.count); deletion not established")
            throw XCTSkip("No exactly dated approved screenshot found; no guessed recovery or permanent deletion")
        }
        XCTAssertTrue(source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved deleted October4 0315 source before recovery")
        let recover = photos.buttons["복구"]
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        recover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB approved one-photo recovery confirmation")
        print("[Task38 actual recovery confirmation] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let confirm = photos.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "사진 복구", "1장의 사진 복구"))
        XCTAssertEqual(confirm.count, 1, "Only exact one-photo recovery confirmation; never Recover All")
        confirm.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB actual one source recovered and candidates2 retained in fresh process")
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["스크린샷을 사용할 수 없음"].exists)
        attach(app, name: "USB same actual deleted source restored in editor; candidate duplication absent")
        print("[Task38 actual recovery] one known photo restored; newProcess candidates2 originalAvailable noSavedEdits")
    }

    func testUSBContinuedRecoveryObservedAlbumTitle() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(photos.staticTexts.matching(identifier: "collectionTitle").matching(NSPredicate(format: "label == %@", "최근 삭제된 항목")).firstMatch.waitForExistence(timeout: 8))
        guard !photos.buttons["앨범 보기"].exists else {
            throw XCTSkip("OS authentication still locked; no other photo touched")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        for _ in 0..<40 {
            if source.count == 1 && source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780 { break }
            photos.swipeUp(velocity: .fast)
        }
        if source.count == 0 {
            attach(photos, name: "USB authenticated Recent Deleted has no exact approved source; deletion not established")
            print("[Task38 exact recovery source absent] " + photos.staticTexts.matching(identifier: "collectionAssetCount").firstMatch.label)
            photos.buttons["PXBarItemIdentifierExplicitBack"].tap()
            XCTAssertTrue(photos.buttons["SearchTab"].waitForExistence(timeout: 8))
            photos.buttons["SearchTab"].tap()
            let input = photos.textViews.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            if input.value as? String != "Task38" { input.tap(); input.typeText("Task38\n") }
            Thread.sleep(forTimeInterval: 3)
            attach(photos, name: "USB live Photos exact source presence after unsuccessful native deletion action")
            print("[Task38 live source presence] exact source count=" + String(photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15")).count))
            throw XCTSkip("Approved source absent from RecentlyDeleted; native deletion not confirmed, no other photo recovered")
        }
        XCTAssertEqual(source.count, 1)
        XCTAssertTrue(source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved deleted October4 0315 source before recovery")
        let recover = photos.buttons["복구"]
        XCTAssertTrue(recover.waitForExistence(timeout: 8))
        recover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB approved one-photo recovery confirmation")
        print("[Task38 actual recovery confirmation] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let confirm = photos.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "사진 복구", "1장의 사진 복구"))
        XCTAssertEqual(confirm.count, 1, "Only exact one-photo recovery confirmation; never Recover All")
        confirm.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB actual one source recovered and candidates2 retained in fresh process")
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["스크린샷을 사용할 수 없음"].exists)
        attach(app, name: "USB same actual deleted source restored in editor; candidate duplication absent")
        print("[Task38 actual recovery] one known photo restored; newProcess candidates2 originalAvailable noSavedEdits")
    }

    func testUSBContinuedDeleteApprovedSourceAndCheckCandidates() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.navigationBars["PUOneUpView"].waitForExistence(timeout: 8))
        XCTAssertTrue(photos.images["스크린샷, Screenshot, 10월 04일, 오전 3:15"].exists)
        XCTAssertTrue(photos.staticTexts["오전 3:15"].exists)
        photos.buttons["PUOneUpBarButtonItemIdentifierTrashBin"].tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB approved one test source deletion OS confirmation")
        print("[Task38 actual source deletion confirmation] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let confirm = photos.buttons["사진 삭제"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "Only observed one-photo Delete Photo confirmation may be accepted")
        confirm.tap()
        Thread.sleep(forTimeInterval: 2)
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        attach(app, name: "USB actual test source deleted; both normal app candidates retained and original unavailable")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        attach(app, name: "USB new process after actual source deletion; two candidates retained")
        print("[Task38 actual deletion] one approved source deleted through OS; candidates2 preserved in new process; restoration required")
    }

    func testUSBContinuedDeleteSourceObservedConfirmationCenter() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.navigationBars["PUOneUpView"].waitForExistence(timeout: 8))
        XCTAssertTrue(photos.images["스크린샷, Screenshot, 10월 04일, 오전 3:15"].exists)
        XCTAssertTrue(photos.staticTexts["오전 3:15"].exists)
        photos.buttons["PUOneUpBarButtonItemIdentifierTrashBin"].tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB approved one test source deletion OS confirmation")
        print("[Task38 actual source deletion confirmation] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        let confirm = photos.buttons["사진 삭제"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "Only observed one-photo Delete Photo confirmation may be accepted")
        confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(photos.navigationBars["PUOneUpView"].exists, "Deletion must actually leave the known source before app inspection")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        attach(app, name: "USB actual test source deleted; both normal app candidates retained and original unavailable")
        app.terminate()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        XCTAssertTrue(app.staticTexts["스크린샷을 사용할 수 없음"].firstMatch.waitForExistence(timeout: 15))
        attach(app, name: "USB new process after actual source deletion; two candidates retained")
        print("[Task38 actual deletion] one approved source deleted through OS; candidates2 preserved in new process; restoration required")
    }

    func testUSBContinuedLocateDeletedApprovedSourceForRecovery() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        if photos.buttons["닫기"].exists { photos.buttons["닫기"].tap() }
        let collections = photos.buttons["CollectionsTab"]
        XCTAssertTrue(collections.waitForExistence(timeout: 8))
        collections.tap()
        XCTAssertTrue(photos.navigationBars["모음"].waitForExistence(timeout: 8))
        let recent = photos.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "bookmarks", "최근 삭제된 항목")).firstMatch
        XCTAssertTrue(recent.exists)
        let rowY = recent.frame.midY / photos.frame.height
        XCTAssertTrue(rowY > 0.15 && rowY < 0.85)
        if recent.frame.minX > photos.frame.width - 40 {
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: rowY)).press(forDuration: 0.1,
                thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: rowY)))
        }
        recent.tap()
        Thread.sleep(forTimeInterval: 2)
        if photos.buttons["앨범 보기"].exists {
            attach(photos, name: "USB deleted test source recovery requires renewed OS authentication")
            throw XCTSkip("OS authentication required again; known test photo is recoverable, no permanent deletion")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        for _ in 0..<40 {
            if source.count == 1 && source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780 { break }
            photos.swipeUp(velocity: .fast)
        }
        XCTAssertEqual(source.count, 1, "Only the exactly dated approved source can be recovered")
        XCTAssertTrue(source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved deleted source opened for recovery; no other photo touched")
        print("[Task38 approved deleted source controls] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
    }

    func testUSBContinuedRecoverFromObservedPhotosControls() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        Thread.sleep(forTimeInterval: 2)
        if photos.buttons["PUOneUpBarButtonItemIdentifierDone"].exists { photos.buttons["PUOneUpBarButtonItemIdentifierDone"].tap() }
        if photos.buttons["닫기"].waitForExistence(timeout: 2) { photos.buttons["닫기"].tap() }
        let collections = photos.buttons["CollectionsTab"]
        XCTAssertTrue(collections.waitForExistence(timeout: 8))
        collections.tap()
        XCTAssertTrue(photos.navigationBars["모음"].waitForExistence(timeout: 8))
        let recent = photos.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "bookmarks", "최근 삭제된 항목")).firstMatch
        XCTAssertTrue(recent.exists)
        let rowY = recent.frame.midY / photos.frame.height
        XCTAssertTrue(rowY > 0.15 && rowY < 0.85)
        if recent.frame.minX > photos.frame.width - 40 {
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: rowY)).press(forDuration: 0.1,
                thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: rowY)))
        }
        recent.tap()
        Thread.sleep(forTimeInterval: 2)
        if photos.buttons["앨범 보기"].exists {
            attach(photos, name: "USB deleted test source recovery requires renewed OS authentication")
            throw XCTSkip("OS authentication required again; known test photo is recoverable, no permanent deletion")
        }
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        for _ in 0..<40 {
            if source.count == 1 && source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780 { break }
            photos.swipeUp(velocity: .fast)
        }
        XCTAssertEqual(source.count, 1, "Only the exactly dated approved source can be recovered")
        XCTAssertTrue(source.firstMatch.frame.midY > 120 && source.firstMatch.frame.midY < 780)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved deleted source opened for recovery; no other photo touched")
        print("[Task38 approved deleted source controls] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
    }

    func testUSBContinuedOpenExactApprovedSource() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.staticTexts["1개의 결과"].waitForExistence(timeout: 8))
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertEqual(source.count, 1)
        source.firstMatch.tap()
        XCTAssertTrue(photos.buttons["PUOneUpBarButtonItemIdentifierTrash"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved October4 0315 source opened before deletion")
        print("[Task38 approved one source] " + photos.debugDescription)
    }

    func testUSBContinuedOpenSourceObservedCenter() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.staticTexts["1개의 결과"].waitForExistence(timeout: 8))
        let source = photos.images.matching(NSPredicate(format: "identifier == %@ AND label == %@", "PXGGridLayout-Info", "스크린샷, Screenshot, 10월 04일, 오전 3:15"))
        XCTAssertEqual(source.count, 1)
        source.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB exact approved October4 0315 source opened before deletion")
        print("[Task38 approved one source] " + photos.debugDescription)
    }

    func testUSBContinuedObservedFocusedPhotoSearch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.keyboards.firstMatch.waitForExistence(timeout: 8))
        // The actual captured Search tab shows the focused bottom native input.
        // It is not exposed as XCTest SearchField; use its observed keyboard focus.
        photos.typeText("Task38\n")
        Thread.sleep(forTimeInterval: 5)
        attach(photos, name: "USB native focused Photos approved Task38 search results; no deletion")
        print("[Task38 observed focused photo search] " + photos.debugDescription)
    }

    func testUSBContinuedAuthenticatedRecoveryAndSourceSearch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        Thread.sleep(forTimeInterval: 2)
        guard !photos.buttons["앨범 보기"].exists else {
            throw XCTSkip("Recently Deleted authentication remains locked; no deletion")
        }
        attach(photos, name: "USB user authenticated Recently Deleted before any deletion")
        print("[Task38 authenticated recovery] " + photos.debugDescription)
        for _ in 0..<3 {
            if photos.buttons["SearchTab"].exists { break }
            let back = photos.navigationBars.buttons.firstMatch
            guard back.exists else { throw XCTSkip("No observed Photos back control; no deletion") }
            back.tap()
        }
        let searchTab = photos.buttons["SearchTab"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 8))
        searchTab.tap()
        let search = photos.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) else {
            attach(photos, name: "USB native Photos search unavailable; no deletion")
            throw XCTSkip("No native search field; no photo selected or deleted")
        }
        search.tap()
        search.typeText("Task38 잔여 검증\n")
        Thread.sleep(forTimeInterval: 4)
        attach(photos, name: "USB native Photos exact approved test source search; no deletion")
        print("[Task38 approved source search] " + photos.debugDescription)
    }

    func testUSBContinuedRecoveryFromObservedShelf() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.navigationBars["모음"].waitForExistence(timeout: 8))
        let recent = photos.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "bookmarks", "최근 삭제된 항목")).firstMatch
        XCTAssertTrue(recent.exists)
        // The captured hierarchy shows x677,y465 in a horizontal shelf.
        // Avoid the failed offscreen isHittable query and vertical swipe path.
        let rowY = recent.frame.midY / photos.frame.height
        guard rowY > 0.15 && rowY < 0.85 else {
            throw XCTSkip("Observed shelf row moved; no guessed viewport tap or deletion")
        }
        if recent.frame.minX > photos.frame.width - 40 {
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: rowY)).press(forDuration: 0.1,
                thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: rowY)))
        }
        XCTAssertTrue(recent.frame.midX > 0 && recent.frame.midX < photos.frame.width)
        recent.tap()
        Thread.sleep(forTimeInterval: 2)
        if photos.buttons["앨범 보기"].exists { photos.buttons["앨범 보기"].tap(); Thread.sleep(forTimeInterval: 2) }
        attach(photos, name: "USB continued recovery access via observed horizontal shelf; no deletion")
        print("[Task38 continued observed recovery] buttons=" + photos.buttons.allElementsBoundByIndex.map { $0.identifier + ":" + $0.label }.joined(separator: ";"))
        print("[Task38 continued observed recovery] notices=" + photos.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("[Task38 continued observed recovery] OS notices=" + springboard.alerts.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBContinuedPhotosRecentlyDeletedAccess() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        let collections = photos.buttons["CollectionsTab"]
        XCTAssertTrue(collections.waitForExistence(timeout: 8))
        collections.tap()
        let recentButton = photos.buttons.matching(NSPredicate(format: "label CONTAINS %@", "최근 삭제된 항목")).firstMatch
        let recentText = photos.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "최근 삭제된 항목")).firstMatch
        for _ in 0..<10 {
            if (recentButton.exists && recentButton.isHittable) || (recentText.exists && recentText.isHittable) { break }
            photos.swipeUp()
        }
        if recentButton.exists && recentButton.isHittable { recentButton.tap() }
        else if recentText.exists && recentText.isHittable { recentText.tap() }
        else {
            attach(photos, name: "USB continued Recently Deleted entry unavailable; no photo deleted")
            throw XCTSkip("Recovery entry unavailable; no deletion performed")
        }
        Thread.sleep(forTimeInterval: 2)
        attach(photos, name: "USB continued Recently Deleted recovery access preparation; no deletion")
        print("[Task38 continued Recently Deleted] buttons=" + photos.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map { "\($0.identifier):\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 continued Recently Deleted] notices=" + photos.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("[Task38 continued Recently Deleted] OS notices=" + springboard.alerts.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBContinuedPhotosRecoveryPreparation() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        let info = photos.buttons["PUOneUpBarButtonItemIdentifierToggleDetails"]
        XCTAssertTrue(info.waitForExistence(timeout: 8))
        info.tap()
        attach(photos, name: "USB continued approved current test photo metadata; no deletion")
        print("[Task38 continued recovery preparation] photo metadata=" + photos.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        info.tap()
        photos.buttons["PUOneUpBarButtonItemIdentifierDone"].tap()
        Thread.sleep(forTimeInterval: 1)
        attach(photos, name: "USB continued Photos recovery entry controls; no deletion")
        print("[Task38 continued recovery preparation] buttons=" + photos.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map { "\($0.identifier):\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 continued recovery preparation] tabs=" + photos.tabBars.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBContinuedPhotosSourceControls() throws {
        try requireTestPhone()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 10))
        attach(photos, name: "USB continued actual Photos starting controls; no asset changed")
        print("[Task38 continued Photos] buttons=" + photos.buttons.allElementsBoundByIndex.filter { $0.isHittable }.map { "\($0.identifier):\($0.label):\($0.frame)" }.joined(separator: ";"))
    }

    func testUSBContinuedZRestoreDisplayBaseline() throws {
        try requireTestPhone()
        continueAfterFailure = false
        var settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
        settings.staticTexts["손쉬운 사용"].tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        let contrast = settings.switches["대비 증가"]
        reveal(contrast, in: settings)
        setSwitch(contrast, to: false)
        settings.buttons["LARGER_TEXT"].tap()
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        setSwitch(settings.switches.firstMatch, to: false)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(slider.value as? String, "50%")
        attach(settings, name: "USB continued final largest text OFF 50 baseline")
        settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
        settings.staticTexts["손쉬운 사용"].tap()
        reveal(settings.staticTexts["동작"], in: settings)
        settings.staticTexts["동작"].tap()
        setSwitch(settings.switches["동작 줄이기"], to: false)
        attach(settings, name: "USB continued final Reduce Motion OFF baseline")
        settings = continuedSettingsRoot()
        revealFromTop(settings.staticTexts["디스플레이 및 밝기"], in: settings)
        settings.staticTexts["디스플레이 및 밝기"].tap()
        XCTAssertTrue(settings.buttons["라이트 모드"].waitForExistence(timeout: 8))
        settings.buttons["라이트 모드"].tap()
        setSwitch(settings.switches["자동"], to: false)
        Thread.sleep(forTimeInterval: 1)
        attach(settings, name: "USB continued final Light AutoOFF baseline")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        attach(app, name: "USB continued final Home after display baseline restoration")
    }

    private func continuedSettingsRoot() -> XCUIApplication {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        if settings.searchFields.firstMatch.exists && settings.buttons["닫기"].exists { settings.buttons["닫기"].tap() }
        // The first foreground transition can briefly have no navigation bar.
        // Wait for the observed root/back control instead of asserting in that gap.
        for _ in 0..<8 {
            if settings.navigationBars["설정"].waitForExistence(timeout: 1) { return settings }
            let back = settings.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
        }
        XCTAssertTrue(settings.navigationBars["설정"].waitForExistence(timeout: 5))
        return settings
    }

    private func inspectContinuedCandidateAndWidgets(_ mode: String) {
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB continued candidate gallery with " + mode)
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        attach(app, name: "USB continued candidate editor original with " + mode)
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !springboard.otherElements.matching(identifier: "SnapSchedule").firstMatch.exists { springboard.swipeLeft() }
        let frames = springboard.otherElements.matching(identifier: "SnapSchedule").allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 150 && $0.frame.height > 150 }
        let uniqueFrames = Set(frames.map { String(describing: $0.frame) })
        XCTAssertEqual(uniqueFrames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.staticTexts["Task38 테스트"].exists })
        attach(springboard, name: "USB continued small and medium Widgets with " + mode)
        print("[Task38 continued display] mode=\(mode) candidates=2 uniqueWidgetFrames=\(uniqueFrames.count); no saved edits")
    }

    func testUSBRealPlannerDelayedCenterColdTapAndRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 900
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        openTestThroughPreparedWidget(app)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "US/Pacific")!
        let target = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(240))
        XCTAssertEqual(target.year, 2026)
        XCTAssertEqual(target.month, 10)
        XCTAssertEqual(target.day, 4)
        let deadline = calendar.date(from: target)!.addingTimeInterval(20)
        var changed = false
        defer { if changed { restoreReminderAfterDelayedCenter(app) } }
        app.buttons["편집"].tap()
        selectTestDate(day: 4, in: app)
        selectTestTime(hour: target.hour!, minute: target.minute!, in: app)
        saveTestSchedule(app)
        changed = true
        let time = "시간, \(target.hour! < 12 ? "오전" : "오후") \(target.hour! % 12 == 0 ? 12 : target.hour! % 12):\(String(format: "%02d", target.minute!))"
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 4일"].exists)
        XCTAssertTrue(app.staticTexts[time].exists)
        attach(app, name: "USB actual planner temporary schedule before delayed Center cold tap")
        print("[Task38 residual notification] actual planner target \(target.hour!):\(target.minute!); no synthetic request; no banner AX queries before target+20s")
        app.terminate()
        XCUIDevice.shared.press(.home)
        var nextLog = Date()
        while Date() < deadline {
            if Date() >= nextLog {
                print("[Task38 residual notification] remaining wait seconds=\(max(0, deadline.timeIntervalSinceNow))")
                nextLog = Date().addingTimeInterval(30)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.8)))
        let title = springboard.staticTexts["Task38 테스트"]
        guard title.waitForExistence(timeout: 10) else {
            attach(springboard, name: "USB after actual deadline without retained test card")
            restoreReminderAfterDelayedCenter(app)
            changed = false
            throw XCTSkip("Actual planner card unavailable after deadline; no synthetic replacement or same query retry")
        }
        attach(springboard, name: "USB actual new planner Center card after banner animation window")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 4일"].exists)
        XCTAssertTrue(app.staticTexts[time].exists)
        attach(app, name: "USB actual new planner Center cold tap matching temporary schedule detail")
        restoreReminderAfterDelayedCenter(app)
        changed = false
        print("[Task38 residual notification] actual Center cold tap reached matching detail; originalOctober5 16:00 restored")
    }

    private func restoreReminderAfterDelayedCenter(_ app: XCUIApplication) {
        if !app.navigationBars["일정"].exists {
            app.launch()
            let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "schedule-original-", "Task38 테스트")).firstMatch
            XCTAssertTrue(original.waitForExistence(timeout: 15), "Temporary October4 schedule must have its original on selected today; do not use the failed text row")
            original.tap()
            XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 10))
        }
        app.buttons["편집"].tap()
        selectTestDate(day: 5, in: app)
        selectTestTime(hour: 16, minute: 0, in: app)
        saveTestSchedule(app)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB original reminder fixture restored after delayed actual Center phase")
    }

    func testUSBPreparedSourceLimitedRemoveReaddAndRestoreFull() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.buttons["완료"].waitForExistence(timeout: 8), "Continue only the prepared limited picker")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        var restoredFull = false
        defer { if !restoredFull { restoreResidualFullPhotos(settings) } }
        //60B4... shows our newly created English-keyboard test screenshot in
        //the top-left tile. Only this one known test asset is ever selected.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.262)).tap()
        settings.buttons["완료"].tap()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB limited one prepared source with both actual candidates retained")

        settings.activate()
        XCTAssertTrue(settings.buttons["선택된 사진 편집"].waitForExistence(timeout: 8))
        settings.buttons["선택된 사진 편집"].tap()
        XCTAssertTrue(settings.buttons["완료"].waitForExistence(timeout: 8))
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.262)).tap()
        settings.buttons["완료"].tap()
        openResidualGallery(app)
        let unavailable = app.staticTexts["스크린샷을 사용할 수 없음"]
        XCTAssertTrue(unavailable.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        attach(app, name: "USB limited test source removed; unavailable cards and both candidates retained")

        settings.activate()
        settings.buttons["선택된 사진 편집"].tap()
        XCTAssertTrue(settings.buttons["완료"].waitForExistence(timeout: 8))
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.262)).tap()
        settings.buttons["완료"].tap()
        openResidualGallery(app)
        XCTAssertEqual(residualCandidateImages(app).count, 2)
        residualCandidateImages(app).firstMatch.tap()
        let original = app.descendants(matching: .any).matching(identifier: "original-screenshot").firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["스크린샷을 사용할 수 없음"].exists)
        attach(app, name: "USB actual prepared source restored while still limited; no candidate duplication")
        restoreResidualFullPhotos(settings)
        app.launch()
        app.buttons["설정"].tap()
        XCTAssertTrue(app.staticTexts["전체 사진 접근"].waitForExistence(timeout: 12))
        attach(app, name: "USB Full Photos baseline restored after real limited-list remove and readd")
        restoredFull = true
        print("[Task38 residual Photos] known source selected→removed→readded under limited; two candidates retained; original restored; Full baseline restored")
    }

    private func residualCandidateImages(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-image-"))
    }

    private func openResidualGallery(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        XCTAssertTrue(residualCandidateImages(app).firstMatch.waitForExistence(timeout: 10))
    }

    private func restoreResidualFullPhotos(_ settings: XCUIApplication) {
        settings.activate()
        if settings.buttons["취소"].exists { settings.buttons["취소"].tap() }
        let full = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "전체 접근")).firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 8))
        full.tap()
        if settings.buttons["전체 접근 허용"].waitForExistence(timeout: 3) { settings.buttons["전체 접근 허용"].tap() }
        else {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.buttons["전체 접근 허용"].waitForExistence(timeout: 3) { springboard.buttons["전체 접근 허용"].tap() }
        }
    }

    func testUSBContinueLimitedFromObservedAppsButton() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.searchFields.firstMatch.exists)
        let appButton = settings.buttons["com.example.SnapSchedule"]
        XCTAssertTrue(appButton.waitForExistence(timeout: 8))
        XCTAssertTrue(appButton.isHittable)
        appButton.tap()
        guard settings.staticTexts["사진"].waitForExistence(timeout: 8) else {
            attach(settings, name: "USB actual Apps native button did not enter test app permissions")
            throw XCTSkip("Observed native Apps button did not open permissions; no same tap repeated")
        }
        settings.staticTexts["사진"].tap()
        let limited = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "제한된 접근")).firstMatch
        XCTAssertTrue(limited.waitForExistence(timeout: 8))
        limited.tap()
        Thread.sleep(forTimeInterval: 1)
        attach(settings, name: "USB actual limited picker through observed native Apps button")
        print("[Task38 residual Photos] limited picker buttons=" + settings.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 residual Photos] limited picker visible cells=" + settings.cells.allElementsBoundByIndex.filter { $0.isHittable }.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
    }

    func testUSBEnterLimitedPickerForPreparedSource() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        if settings.searchFields.firstMatch.exists && settings.buttons["닫기"].exists { settings.buttons["닫기"].tap() }
        openSystemRoot(settings)
        revealFromTop(settings.staticTexts["앱"], in: settings)
        settings.staticTexts["앱"].tap()
        let field = settings.searchFields.firstMatch
        if !field.exists { settings.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("SnapSchedule")
        settings.staticTexts["SnapSchedule"].tap()
        settings.staticTexts["사진"].tap()
        let limited = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "제한된 접근")).firstMatch
        XCTAssertTrue(limited.waitForExistence(timeout: 8))
        limited.tap()
        Thread.sleep(forTimeInterval: 1)
        attach(settings, name: "USB initial actual limited Photos picker for newly created test source; no selection guessed")
        print("[Task38 residual Photos] picker buttons=" + settings.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 residual Photos] visible picker cell controls=" + settings.cells.allElementsBoundByIndex.filter { $0.isHittable }.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
    }

    func testUSBCreatePreparedNoteSystemScreenshot() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = captureSettings()
        let toggle = settings.switches["AssistiveTouch"]
        setSwitch(toggle, to: true)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).tap()
            settings.activate()
            Thread.sleep(forTimeInterval: 1.5)
            setSwitch(toggle, to: false)
        }
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains("Task38 잔여 검증"))
        Thread.sleep(forTimeInterval: 1.5)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.725, dy: 0.956)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.695, dy: 0.72)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.85)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        //6E78... captured Screenshot at(.705,.655) in the More submenu.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.705, dy: 0.655)).tap()
        Thread.sleep(forTimeInterval: 2)
        attach(springboard, name: "USB prepared test note after actual system screenshot control")
        print("[Task38 residual capture] system screenshot control touched epoch=\(Date().timeIntervalSince1970); buttons=" + springboard.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        if springboard.buttons["완료"].exists { springboard.buttons["완료"].tap() }
        if springboard.buttons["사진 앱에 저장"].exists { springboard.buttons["사진 앱에 저장"].tap() }
    }

    func testUSBInspectNewResidualCandidateWithoutEditing() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        print("[Task38 residual capture] postcapture candidate count label=\(review.label)")
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        let images = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-image-"))
        guard images.firstMatch.waitForExistence(timeout: 10) else {
            attach(app, name: "USB residual candidate gallery without new source after capture control")
            throw XCTSkip("System capture has not produced an observable candidate; no imported replacement")
        }
        attach(app, name: "USB residual actual PhotoKit new candidate source gallery")
        print("[Task38 residual capture] new source candidate image count=\(images.count)")
        XCTAssertEqual(images.count, 1, "Never open an unrelated candidate")
        images.firstMatch.tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        print("[Task38 residual capture] observed title=\(String(describing: app.textFields["제목"].value))")
        attach(app, name: "USB residual actual new PhotoKit candidate fields inspection only")
    }

    func testUSBReadCurrentOSControlsForCleanup() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        attach(settings, name: "USB current OS controls before temporary capture setting cleanup")
        print("[Task38 residual cleanup] buttons=" + settings.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.identifier):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 residual cleanup] bars=" + settings.navigationBars.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        print("[Task38 residual cleanup] search field count=\(settings.searchFields.count)")
    }

    func testUSBObservedCaptureMoreMenuAndRestoreControl() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = captureSettings()
        let toggle = settings.switches["AssistiveTouch"]
        setSwitch(toggle, to: true)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer {
            // Dismiss the floating menu before touching underlying Settings.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).tap()
            settings.activate()
            Thread.sleep(forTimeInterval: 1.5)
            setSwitch(toggle, to: false)
            attach(settings, name: "USB temporary capture control restored OFF after menu dismissal")
        }
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains("Task38 잔여 검증"))
        Thread.sleep(forTimeInterval: 1.5)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.725, dy: 0.956)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.695, dy: 0.72)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        //F33F... showed More at(.62,.85); never touch Lock or Volume.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.85)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        attach(springboard, name: "USB observed native capture More submenu over test note")
        print("[Task38 residual capture] reached observed More submenu; dismissal precedes OFF restoration")
    }

    private func captureSettings() -> XCUIApplication {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        //The actual Apps search is a sheet with Close, not a navigation bar.
        if settings.searchFields.firstMatch.exists && settings.buttons["닫기"].exists {
            settings.buttons["닫기"].tap()
        }
        if !settings.switches["AssistiveTouch"].exists {
            openSystemRoot(settings)
            revealFromTop(settings.staticTexts["손쉬운 사용"], in: settings)
            settings.staticTexts["손쉬운 사용"].tap()
            reveal(settings.staticTexts["터치"], in: settings)
            settings.staticTexts["터치"].tap()
            settings.staticTexts["AssistiveTouch"].tap()
        }
        XCTAssertTrue(settings.switches["AssistiveTouch"].waitForExistence(timeout: 8))
        return settings
    }

    func testUSBRestoreCaptureControlAfterAppsSearch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = captureSettings()
        setSwitch(settings.switches["AssistiveTouch"], to: false)
        XCTAssertEqual(settings.switches["AssistiveTouch"].value as? String, "0")
        attach(settings, name: "USB temporary capture control verified OFF after closing actual Apps search sheet")
        print("[Task38 residual cleanup] AssistiveTouch OFF confirmed after observed Close control")
    }

    func testUSBObservedCaptureDeviceSubmenu() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = captureSettings()
        let toggle = settings.switches["AssistiveTouch"]
        setSwitch(toggle, to: true)
        defer {
            settings.activate()
            setSwitch(toggle, to: false)
        }
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains("Task38 잔여 검증"))
        Thread.sleep(forTimeInterval: 1.5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.725, dy: 0.956)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        //661D... captured Device at normalized(.695,.72) in the menu.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.695, dy: 0.72)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        attach(springboard, name: "USB observed native capture Device submenu")
        print("[Task38 residual capture] Device submenu controls=" + springboard.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
    }

    func testUSBPhotosChoicesThroughOSApps() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let apps = settings.staticTexts["앱"]
        revealFromTop(apps, in: settings)
        apps.tap()
        let field = settings.searchFields.firstMatch
        if !field.exists { settings.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("SnapSchedule")
        let entry = settings.staticTexts["SnapSchedule"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(settings.staticTexts["사진"].waitForExistence(timeout: 8))
        settings.staticTexts["사진"].tap()
        XCTAssertTrue(settings.staticTexts["전체 접근"].waitForExistence(timeout: 8))
        attach(settings, name: "USB actual Photos choices reached through OS Apps list")
        print("[Task38 residual Photos] cells=" + settings.cells.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 residual Photos] buttons=" + settings.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBObservedCaptureMenuAndPhotoChoices() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains("Task38 잔여 검증"))
        if notes.buttons["선택됨"].exists { notes.buttons["선택됨"].tap() }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let toggle = settings.switches["AssistiveTouch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        setSwitch(toggle, to: true)
        defer {
            settings.activate()
            if toggle.exists { setSwitch(toggle, to: false) }
        }
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        // Screenshot evidence626A... showed the system floating control at
        // normalized(.725,.956). The Springboard AX tree did not expose it.
        Thread.sleep(forTimeInterval: 1.5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.725, dy: 0.956)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        attach(springboard, name: "USB native capture menu after observed floating control coordinate")
        let assistive = XCUIApplication(bundleIdentifier: "com.apple.AssistiveTouch")
        print("[Task38 residual capture] AssistiveTouch menu buttons=" + assistive.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        print("[Task38 residual capture] Springboard menu buttons=" + springboard.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
    }

    func testUSBResidualLimitedPhotoChoicesOnly() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openAppPermissions(app)
        settings.staticTexts["사진"].tap()
        XCTAssertTrue(settings.staticTexts["전체 접근"].waitForExistence(timeout: 8))
        attach(settings, name: "USB residual actual Photos limited choice before any change")
        print("[Task38 residual Photos] available cells=" + settings.cells.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        print("[Task38 residual Photos] buttons=" + settings.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        app.activate()
    }

    func testUSBRestoreTimeThroughPreparedWidget() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        openTestThroughPreparedWidget(app)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:05"].exists)
        app.buttons["편집"].tap()
        selectTestTime(hour: 16, minute: 0, in: app)
        saveTestSchedule(app)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB original16:00 restored through prepared Widget detail")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !springboard.otherElements.matching(identifier: "SnapSchedule").firstMatch.exists { springboard.swipeLeft() }
        let times = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4:00"))
        XCTAssertTrue(times.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(times.count, 2)
        attach(springboard, name: "USB both prepared Widget sizes actual reload back to16:00")
        openTestThroughPreparedWidget(app)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB restored original schedule in new process via Widget")
        print("[Task38 residual Widget] original16:00 saved; both Widget sizes reloaded; new process confirms restoration")
    }

    private func openTestThroughPreparedWidget(_ app: XCUIApplication) {
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !springboard.otherElements.matching(identifier: "SnapSchedule").firstMatch.exists { springboard.swipeLeft() }
        let cards = springboard.otherElements.matching(identifier: "SnapSchedule").allElementsBoundByIndex.filter { $0.frame.width > 150 && $0.frame.height > 150 && $0.isHittable }
        XCTAssertFalse(cards.isEmpty)
        let card = cards.first!
        XCTAssertTrue(card.staticTexts["Task38 테스트"].exists)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 15))
    }

    func testUSBExistingTestNoteCaptureOverlay() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue((notes.textViews.firstMatch.value as? String ?? "").contains("Task38 잔여 검증"), "Use only the newly created test note")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let toggle = settings.switches["AssistiveTouch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "0")
        defer {
            settings.activate()
            if toggle.exists { setSwitch(toggle, to: false) }
            notes.activate()
        }
        setSwitch(toggle, to: true)
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let overlay = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", "AssistiveTouch", "AssistiveTouch"))
        print("[Task38 residual capture] observed overlay=" + overlay.allElementsBoundByIndex.map { "\($0.elementType):\($0.label):\($0.identifier):\($0.frame)" }.joined(separator: ";"))
        attach(notes, name: "USB prepared test note with native AssistiveTouch enabled")
        guard overlay.firstMatch.waitForExistence(timeout: 5), overlay.firstMatch.isHittable else {
            throw XCTSkip("Native floating capture control not exposed in Springboard; do not guess coordinates")
        }
        overlay.firstMatch.tap()
        attach(springboard, name: "USB native AssistiveTouch capture menu over prepared test note")
        print("[Task38 residual capture] menu button labels=" + springboard.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBCreateResidualTestNoteAndInspectCaptureMenu() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        if notes.buttons["메모"].exists { notes.buttons["메모"].tap() }
        let compose = notes.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR identifier == %@", "새로운 메모", "메모 작성", "Compose")).firstMatch
        print("[Task38 residual capture] Notes list button labels=" + notes.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        guard compose.waitForExistence(timeout: 5), compose.isHittable else {
            throw XCTSkip("New note compose must be observed; existing note is never replaced")
        }
        compose.tap()
        let field = notes.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let initial = field.value as? String ?? ""
        XCTAssertTrue(initial.isEmpty || initial == "메모", "Only an empty new note may be populated")
        field.tap()
        field.typeText("Task38 잔여 검증\n2026년 10월 6일 오후 4시\n장소: 테스트룸")
        XCTAssertTrue((field.value as? String ?? "").contains("Task38 잔여 검증"))
        notes.swipeDown()
        attach(notes, name: "USB newly created privacy-free residual test note before screenshot")
        print("[Task38 residual capture] new test note created; no existing note content replaced")

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let toggle = settings.switches["AssistiveTouch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "0")
        defer {
            settings.activate()
            if toggle.exists && toggle.value as? String == "1" { toggle.tap() }
            notes.activate()
        }
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("[Task38 residual capture] overlay buttons=" + springboard.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        let assistive = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", "AssistiveTouch", "AssistiveTouch")).firstMatch
        guard assistive.waitForExistence(timeout: 5) else {
            attach(notes, name: "USB test note with screenshot overlay; capture control not yet resolved")
            throw XCTSkip("AssistiveTouch screenshot overlay button must be observed; baseline restored")
        }
        assistive.tap()
        attach(springboard, name: "USB observed screenshot overlay menu above test note")
        print("[Task38 residual capture] opened menu buttons=" + springboard.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBWidgetTimeReloadAndRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        var changed = false
        defer { if changed { restoreOriginalTestSchedule(app) } }
        app.buttons["편집"].tap()
        selectTestTime(hour: 16, minute: 5, in: app)
        saveTestSchedule(app)
        changed = true
        XCTAssertTrue(app.staticTexts["시간, 오후 4:05"].exists)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var roots = springboard.otherElements.matching(identifier: "SnapSchedule")
        if !roots.firstMatch.exists { springboard.swipeLeft() }
        roots = springboard.otherElements.matching(identifier: "SnapSchedule")
        let updated = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4:05"))
        XCTAssertTrue(updated.firstMatch.waitForExistence(timeout: 45), "Wait for actual WidgetKit timeline reload")
        let frames = Set(roots.allElementsBoundByIndex.filter { $0.frame.width > 150 && $0.frame.height > 150 }.map { String(describing: $0.frame) })
        XCTAssertEqual(frames.count, 2, "Both prepared Widget sizes must be present")
        XCTAssertEqual(updated.count, 2, "Both small and medium must display the updated time")
        attach(springboard, name: "USB small and medium Widget actual reload to 16:05")
        restoreOriginalTestSchedule(app)
        changed = false
        XCUIDevice.shared.press(.home)
        if !springboard.otherElements["SnapSchedule"].firstMatch.exists { springboard.swipeLeft() }
        let restored = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4:00"))
        XCTAssertTrue(restored.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(restored.count, 2)
        attach(springboard, name: "USB small and medium Widget restored original time 16:00")
        print("[Task38 residual Widget] actual local edit16:00→16:05→16:00; both sizes reloaded; existing Calendar copy not rewritten")
    }

    func testUSBInstalledWidgetPagesAndColdTap() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var observedSizes = Set<String>()
        for page in 0..<2 {
            app.terminate()
            XCUIDevice.shared.press(.home)
            if springboard.buttons["완료"].exists { springboard.buttons["완료"].tap() }
            // The observed Home Screen has two pages. Home returns to page one.
            if page == 1 { springboard.swipeLeft() }
            attach(springboard, name: "USB prepared Widget Home Screen page \(page + 1)")
            let cards = springboard.otherElements.matching(NSPredicate(format: "label == %@", "SnapSchedule"))
            let roots = cards.allElementsBoundByIndex.filter { $0.frame.width > 150 && $0.frame.height > 150 && $0.isHittable }
            var frames = Set<String>()
            for card in roots {
                let frame = card.frame
                guard frames.insert(String(describing: frame)).inserted else { continue }
                let size = frame.width > frame.height * 1.5 ? "medium" : "small"
                print("[Task38 residual Widget] page\(page + 1) \(size) frame=\(frame)")
                XCTAssertTrue(card.staticTexts["Task38 테스트"].exists)
                card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
                XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 15))
                XCTAssertTrue(app.staticTexts["Task38 테스트"].exists)
                XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
                XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
                attach(app, name: "USB \(size) Widget cold direct card tap matching schedule")
                observedSizes.insert(size)
                app.terminate()
                XCUIDevice.shared.press(.home)
                if page == 1 { springboard.swipeLeft() }
            }
        }
        print("[Task38 residual Widget] verified sizes=" + observedSizes.sorted().joined(separator: ","))
        guard !observedSizes.isEmpty else { throw XCTSkip("No prepared Widget root found on the two observed pages") }
    }

    func testUSBPrepareNewCaptureControls() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        let touch = settings.staticTexts["터치"]
        reveal(touch, in: settings)
        touch.tap()
        XCTAssertTrue(settings.staticTexts["AssistiveTouch"].waitForExistence(timeout: 8))
        settings.staticTexts["AssistiveTouch"].tap()
        XCTAssertTrue(settings.switches["AssistiveTouch"].waitForExistence(timeout: 8))
        attach(settings, name: "USB screenshot control AssistiveTouch unchanged baseline")
        print("[Task38 residual capture] AssistiveTouch baseline=\(String(describing: settings.switches["AssistiveTouch"].value))")
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        // Do not record existing note text or capture a private note screen.
        print("[Task38 residual capture] Notes button labels=" + notes.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
    }

    func testUSBExistingSmallWidgetDirectTap() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["완료"].exists { springboard.buttons["완료"].tap() }
        let title = springboard.staticTexts["Task38 테스트"]
        guard title.waitForExistence(timeout: 8) else {
            throw XCTSkip("Observed test widget is no longer on the current Home Screen; do not enter widget installation")
        }
        XCTAssertTrue(title.isHittable)
        attach(springboard, name: "USB existing small Widget before cold direct card tap")
        title.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Task38 테스트"].exists)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB existing small Widget cold direct tap matching schedule detail")
        print("[Task38 residual Widget] observed existing small card cold tap opened matching October5 16:00 detail")
    }

    func testUSBNativeCalendarObservedDateOnly() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let calendarApp = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        calendarApp.activate()
        XCTAssertTrue(calendarApp.wait(for: .runningForeground, timeout: 10))
        let day = calendarApp.buttons["10월 5일 월요일"]
        guard day.waitForExistence(timeout: 8), day.isHittable else {
            throw XCTSkip("Observed October5 day control is unavailable; no search retry")
        }
        day.tap()
        // Locate only the approved test event, never another visible account event.
        let event = calendarApp.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Task38 테스트")).firstMatch
        for _ in 0..<3 {
            if event.exists && event.isHittable { break }
            calendarApp.swipeUp()
        }
        attach(calendarApp, name: "USB Calendar October5 via observed date button without search")
        guard event.exists && event.isHittable else {
            print("[Task38 residual Calendar] no approved event visible after observed date navigation; account copy remains unverified")
            throw XCTSkip("Approved event not visible in the bounded October5 viewport; no search or export retry")
        }
        print("[Task38 residual Calendar] approved day event: \(event.label)")
        event.tap()
        XCTAssertTrue(calendarApp.buttons["편집"].waitForExistence(timeout: 8))
        XCTAssertTrue(calendarApp.staticTexts["Task38 테스트"].exists)
        attach(calendarApp, name: "USB approved existing Calendar copy detail via day navigation")
        print("[Task38 residual Calendar] approved detail fields: " + calendarApp.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        calendarApp.buttons["편집"].tap()
        XCTAssertTrue(calendarApp.buttons["취소"].waitForExistence(timeout: 8))
        attach(calendarApp, name: "USB approved existing Calendar copy duration alarm inspection without saving")
        print("[Task38 residual Calendar] approved editor fields: " + calendarApp.cells.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        calendarApp.buttons["취소"].tap()
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    /// Residual-condition observation only. Does not edit Home Screen, search
    /// Calendar, reschedule reminders, change permissions, or modify photos.
    func testUSBResidualPreparedConditions() throws {
        try requireTestPhone()
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attach(springboard, name: "USB residual current Home Screen conditions")
        let widgets = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "SnapSchedule", "Task38 테스트"))
        print("[Task38 residual conditions] Home relevant controls: " + widgets.allElementsBoundByIndex.map { "\($0.elementType):\($0.label):\($0.frame)" }.joined(separator: ";"))

        let calendarApp = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        calendarApp.activate()
        XCTAssertTrue(calendarApp.wait(for: .runningForeground, timeout: 10))
        attach(calendarApp, name: "USB residual existing Calendar screen without search or export")
        print("[Task38 residual conditions] Calendar buttons: " + calendarApp.buttons.allElementsBoundByIndex.map { "\($0.label):\($0.frame)" }.joined(separator: ";"))
        // Record only the explicitly authorized test title, not other events.
        print("[Task38 residual conditions] approved Calendar title occurrences: \(calendarApp.staticTexts.matching(identifier: "Task38 테스트").count)" )

        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        attach(app, name: "USB residual actual Home after condition observation")
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 8))
        print("[Task38 residual conditions] candidate review: \(review.label)")
        let schedules = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "schedule-detail-", "Task38 테스트"))
        print("[Task38 residual conditions] approved schedule identities visible: \(Set(schedules.allElementsBoundByIndex.map { $0.identifier }).count)")
    }

    func testUSBHomeAndCandidateNavigation() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Task38 physical test-phone UI only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_UI_VALIDATION"] == "1",
              ProcessInfo.processInfo.environment["TASK38_UI_DEVICE_UDID"] == "00000000-0000000000000000" else {
            throw XCTSkip("Explicit Task38 test-phone invocation required")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20), "Actual Home must be observable")
        attach(app, name: "USB actual Home before navigation")
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 8), "Actual candidate-review control must exist")
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual candidate gallery after tap")
        print("[Task38 USB UI] actual Home observed; candidate-review tap and destination verified")
        #endif
    }

    func testUSBInspectTestCandidate() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-detail-"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 8), "Wait for lazy gallery card")
        XCTAssertEqual(cards.count, 1, "Do not select an unrelated candidate")
        cards.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        attach(app, name: "USB test candidate editor top")
        print("[Task38 USB UI] title fields: " + app.textFields.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] title views: " + app.textViews.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        app.swipeUp()
        attach(app, name: "USB test candidate review and reminder controls")
        print("[Task38 USB UI] switches: " + app.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        app.swipeUp()
        attach(app, name: "USB test candidate registration and original")
        print("[Task38 USB UI] lower switches: " + app.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
    }

    func testUSBReviewSaveRegisterAndRelaunch() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyCandidate(app)
        let title = app.textFields["제목"]
        XCTAssertEqual(title.value as? String, "<", "Only the observed test screenshot may be changed")
        replace(title, with: "Task38 UNSAVED")
        attach(app, name: "USB actual unsaved candidate edit before termination")
        app.terminate()
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "<", "Unsaved review must not leak across a new process")
        replace(app.textFields["제목"], with: "Task38 테스트")
        app.buttons["완료"].tap()
        reveal(app.switches["추정한 시간대 확인"], in: app)
        XCTAssertEqual(app.switches["추정한 시간대 확인"].value as? String, "0")
        setSwitch(app.switches["추정한 시간대 확인"], to: true)
        XCTAssertEqual(app.switches["추정한 시간대 확인"].value as? String, "1")
        attach(app, name: "USB reviewed test candidate with device inferred zone confirmed")
        app.navigationBars.buttons["저장"].tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        let register = app.buttons["후보 등록"]
        reveal(register, in: app)
        XCTAssertTrue(register.isEnabled)
        XCTAssertEqual(app.switches["등록 후 캘린더에 추가"].value as? String, "0", "Registration must not export implicitly")
        register.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        attach(app, name: "USB actual registration result")
        app.alerts.buttons["확인"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        attach(app, name: "USB actual Home after test registration and new process")
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Task38 테스트")).firstMatch.waitForExistence(timeout: 8))
        attach(app, name: "USB actual registered test schedule detail")
        print("[Task38 USB UI] real PhotoKit candidate: unsaved edit discarded; saved review retained; UI registration and new-process detail retained")
        print("[Task38 USB UI] runner current epoch=\(Date().timeIntervalSince1970), zone=\(TimeZone.current.identifier)")
    }

    func testUSBCompleteReviewedCandidateRegistration() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "<")
        replace(app.textFields["제목"], with: "Task38 테스트")
        app.buttons["완료"].tap()
        let confirmation = app.switches["추정한 시간대 확인"]
        reveal(confirmation, in: app)
        setSwitch(confirmation, to: true)
        attach(app, name: "USB actual confirmed candidate review")
        app.navigationBars.buttons["저장"].tap()
        app.terminate()
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        let register = app.buttons["후보 등록"]
        reveal(register, in: app)
        XCTAssertTrue(register.isEnabled)
        XCTAssertEqual(app.switches["등록 후 캘린더에 추가"].value as? String, "0")
        attach(app, name: "USB actual saved review after new process before registration")
        register.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        attach(app, name: "USB actual registration result")
        app.alerts.buttons["확인"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        attach(app, name: "USB actual Home after registration and new process")
        openOnlyTestSchedule(app)
        attach(app, name: "USB actual test schedule detail after new process")
        print("[Task38 USB UI] reviewed title saved across process; actual UI registration retained across process")
        print("[Task38 USB UI] runner epoch=\(Date().timeIntervalSince1970), zone=\(TimeZone.current.identifier)")
    }

    func testUSBResumeSavedReviewRegistration() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트<")
        replace(app.textFields["제목"], with: "Task38 테스트")
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        app.buttons["완료"].tap()
        app.navigationBars.buttons["저장"].tap()
        app.terminate()
        app.launch()
        openOnlyCandidate(app)
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        let register = app.buttons["후보 등록"]
        reveal(register, in: app)
        XCTAssertTrue(register.isEnabled)
        XCTAssertEqual(app.switches["등록 후 캘린더에 추가"].value as? String, "0")
        attach(app, name: "USB saved reviewed test candidate after new process")
        register.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        attach(app, name: "USB actual registration result")
        app.alerts.buttons["확인"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        attach(app, name: "USB actual Home after registration and new process")
        openOnlyTestSchedule(app)
        attach(app, name: "USB actual test schedule detail after new process")
        print("[Task38 USB UI] reviewed title saved across process; actual UI registration retained across process")
        print("[Task38 USB UI] runner epoch=\(Date().timeIntervalSince1970), zone=\(TimeZone.current.identifier)")
    }

    private func setSwitch(_ element: XCUIElement, to enabled: Bool) {
        let expected = enabled ? "1" : "0"
        if element.value as? String == expected { return }
        // SwiftUI exposes both a labelled row and a nested native switch.
        // Tap the native control, not the centre of the whole Form row.
        let native = element.switches.firstMatch
        if native.exists { native.tap() }
        else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
    }

    func testUSBInspectSystemNotificationSettings() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 20))
        app.buttons["설정"].tap()
        XCTAssertTrue(app.buttons["알림 설정 열기"].waitForExistence(timeout: 8))
        app.buttons["알림 설정 열기"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        attach(settings, name: "USB actual OS notification settings baseline")
        print("[Task38 USB UI] OS notification switches: " + settings.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] OS navigation: " + settings.navigationBars.allElementsBoundByIndex.map { $0.identifier }.joined(separator: ";"))
        app.activate()
    }

    func testUSBNotificationDeniedKeepsSchedule() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openNotificationSettings(app)
        XCTAssertEqual(settings.switches["알림 허용"].value as? String, "1")
        setSwitch(settings.switches["알림 허용"], to: false)
        attach(settings, name: "USB actual OS notifications denied")
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "거부됨")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["완료"].tap()
        attach(app, name: "USB Home after OS notification denial")
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        attach(app, name: "USB saved schedule retained after notification denial and relaunch")
        print("[Task38 USB UI] OS notifications denied; local registered schedule retained; leave denied for scoped API observation")
    }

    func testUSBRestoreNotificationAuthorization() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openNotificationSettings(app)
        XCTAssertEqual(settings.switches["알림 허용"].value as? String, "0")
        setSwitch(settings.switches["알림 허용"], to: true)
        attach(settings, name: "USB actual OS notifications restored")
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "허용됨")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["완료"].tap()
        attach(app, name: "USB Home after notification reauthorization")
        openOnlyTestSchedule(app)
        attach(app, name: "USB schedule after notification reauthorization")
        print("[Task38 USB UI] OS notification authorization restored; Home and local schedule retained")
    }

    func testUSBFinishDenialAndRestoreNotifications() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        attach(app, name: "USB new-process Home while OS notifications denied")
        openOnlyTestSchedule(app)
        attach(app, name: "USB local schedule preserved while notifications denied")
        app.terminate()
        app.launch()
        let settings = openNotificationSettings(app)
        XCTAssertEqual(settings.switches["알림 허용"].value as? String, "0")
        setSwitch(settings.switches["알림 허용"], to: true)
        attach(settings, name: "USB OS notification authorization restored")
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "허용됨")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["완료"].tap()
        attach(app, name: "USB actual Home after OS notification authorization restored")
        openOnlyTestSchedule(app)
        attach(app, name: "USB local schedule after notification restoration")
        print("[Task38 USB UI] denial preserved schedule across process; OS authorization restored; app Settings allowed and Home observed")
    }

    func testUSBInspectDisplaySettingsAndInstalledWidgets() throws {
        try requireTestPhone()
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attach(springboard, name: "USB actual Home Screen widget baseline")
        print("[Task38 USB UI] visible SnapSchedule widget controls: " + springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "SnapSchedule", "Task38 테스트")).allElementsBoundByIndex.map { String(describing: $0.elementType) + ":" + $0.label }.joined(separator: ";"))
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        for _ in 0..<7 {
            if settings.navigationBars["설정"].exists { break }
            guard settings.navigationBars.buttons.firstMatch.exists else { break }
            settings.navigationBars.buttons.firstMatch.tap()
        }
        let display = settings.staticTexts["디스플레이 및 밝기"]
        reveal(display, in: settings)
        display.tap()
        attach(settings, name: "USB actual OS display settings baseline")
        print("[Task38 USB UI] appearance controls: " + settings.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "라이트", "다크")).allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] display switches: " + settings.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").activate()
    }

    func testUSBCalendarDenialAndAppPermissionScreen() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyTestSchedule(app)
        app.buttons["캘린더에 추가"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 12))
        XCTAssertTrue(permission.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "캘린더")).firstMatch.exists)
        attach(springboard, name: "USB actual Calendar permission request")
        let deny = permission.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "허용 안", "허용하지"))
        XCTAssertEqual(deny.count, 1)
        deny.firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        attach(app, name: "USB Calendar denial preserves local registration")
        app.alerts.buttons["확인"].tap()
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.buttons["다시 시도"].waitForExistence(timeout: 8))
        attach(app, name: "USB persisted Calendar failure after new process")
        app.terminate()
        app.launch()
        app.buttons["설정"].tap()
        XCTAssertTrue(app.buttons["앱 설정 열기"].waitForExistence(timeout: 8))
        app.buttons["앱 설정 열기"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        attach(settings, name: "USB actual app permissions Photos and Calendar baseline")
        print("[Task38 USB UI] app permission choices: " + settings.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "사진", "캘린더")).allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        app.activate()
        print("[Task38 USB UI] first Calendar request denied; local schedule and explicit retry retained across process")
    }

    func testUSBReadDisplaySettingsFromTop() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        for _ in 0..<7 {
            if settings.navigationBars["설정"].exists { break }
            guard settings.navigationBars.buttons.firstMatch.exists else { break }
            settings.navigationBars.buttons.firstMatch.tap()
        }
        let display = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "밝기")).firstMatch
        for _ in 0..<8 {
            if display.exists && display.isHittable { break }
            settings.swipeDown()
        }
        XCTAssertTrue(display.exists && display.isHittable)
        display.tap()
        attach(settings, name: "USB actual OS display and brightness baseline from top")
        print("[Task38 USB UI] appearance controls: " + settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "라이트", "다크")).allElementsBoundByIndex.map { String(describing: $0.elementType) + ":" + $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] display switches: " + settings.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").activate()
    }

    func testUSBPhotoPermissionLossAndRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openAppPermissions(app)
        settings.staticTexts["사진"].tap()
        let full = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "전체 접근")).firstMatch
        let none = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "없음", "안 함")).firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 8))
        XCTAssertTrue(none.exists)
        attach(settings, name: "USB actual Photos permission choices before change")
        // The user already granted Full Photos access. Restore that exact baseline.
        defer {
            settings.activate()
            if full.exists { full.tap() }
            app.activate()
        }
        none.tap()
        attach(settings, name: "USB actual Photos access revoked")
        app.activate()
        if app.navigationBars["설정"].exists && app.buttons["완료"].exists { app.buttons["완료"].tap() }
        openOnlyTestSchedule(app)
        let unavailable = app.staticTexts["스크린샷을 사용할 수 없음"]
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        attach(app, name: "USB actual PhotoKit original unavailable with saved schedule retained")
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.exists)
        settings.activate()
        full.tap()
        attach(settings, name: "USB actual Full Photos access restored")
        app.activate()
        if app.navigationBars["홈"].exists { openOnlyTestSchedule(app) }
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "original-screenshot")).firstMatch
        reveal(original, in: app)
        XCTAssertTrue(original.waitForExistence(timeout: 12))
        attach(app, name: "USB original PhotoKit image restored without registration loss")
        print("[Task38 USB UI] actual Photos permission revoked, original unavailable, saved schedule retained after new process, Full access and original restored")
    }

    func testUSBConfirmPhotosRestoreAndOriginal() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        settings.activate()
        let allow = settings.buttons["전체 접근 허용"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        else if springboard.buttons["전체 접근 허용"].waitForExistence(timeout: 3) {
            springboard.buttons["전체 접근 허용"].tap()
        } else { XCTFail("Only the known Full-access restoration confirmation may be accepted") }
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyTestSchedule(app)
        reveal(app.buttons["원본 스크린샷 보기"], in: app)
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "original-screenshot")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        attach(app, name: "USB actual original restored after OS Full-access confirmation")
        print("[Task38 USB UI] prior Full Photos baseline restored through OS confirmation; actual source image available; local schedule retained")
    }

    func testUSBSystemDarkThenLight() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let display = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "밝기")).firstMatch
        revealFromTop(display, in: settings)
        display.tap()
        XCTAssertTrue(settings.buttons["라이트 모드"].waitForExistence(timeout: 8))
        XCTAssertEqual(settings.switches["자동"].value as? String, "0")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer {
            settings.activate()
            if settings.buttons["라이트 모드"].exists { settings.buttons["라이트 모드"].tap() }
            app.activate()
        }
        settings.buttons["다크 모드"].tap()
        attach(settings, name: "USB actual OS Dark mode selected")
        app.launch()
        attach(app, name: "USB real Home with OS Dark mode")
        openOnlyTestSchedule(app)
        attach(app, name: "USB real schedule with OS Dark mode")
        app.buttons["편집"].tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        attach(app, name: "USB real edit form with OS Dark mode")
        app.buttons["취소"].tap()
        settings.activate()
        settings.buttons["라이트 모드"].tap()
        attach(settings, name: "USB actual OS Light mode restored")
        app.launch()
        attach(app, name: "USB real Home with OS Light mode restored")
        print("[Task38 USB UI] actual OS Dark and Light switches, real Home/detail/editor observed, baseline Light restored")
    }

    func testUSBInspectAccessibilityDisplayOptions() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        let display = settings.staticTexts["디스플레이 및 텍스트 크기"]
        XCTAssertTrue(display.waitForExistence(timeout: 8))
        display.tap()
        attach(settings, name: "USB actual OS text size and contrast baseline")
        print("[Task38 USB UI] text and contrast switches: " + settings.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] text size controls: " + settings.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "텍스트")).allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").activate()
    }

    private func openAppPermissions(_ app: XCUIApplication) -> XCUIApplication {
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 20))
        app.buttons["설정"].tap()
        let open = app.buttons["앱 설정 열기"]
        reveal(open, in: app)
        open.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(settings.staticTexts["사진"].waitForExistence(timeout: 8))
        return settings
    }

    private func openSystemRoot(_ settings: XCUIApplication) {
        settings.activate()
        for _ in 0..<7 {
            if settings.navigationBars["설정"].exists { return }
            guard settings.navigationBars.buttons.firstMatch.exists else { break }
            settings.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(settings.navigationBars["설정"].exists)
    }

    private func revealFromTop(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    func testUSBTenMinuteRealUIAndAppMemory() throws {
        try requireTestPhone()
        continueAfterFailure = false
        executionTimeAllowance = 900 // Warm-up and UI overhead are outside the measured600s.
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 20))
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        var invocation = 0
        var measuredCycles = 0
        var measuredCycleSeconds: [Double] = []
        // XCTest performs one discarded warm-up invocation. Keep it to one cycle.
        // Only the second invocation is the measured ten-minute local-image workload.
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()], options: options) {
            invocation += 1
            let duration: TimeInterval = invocation == 1 ? 0 : 600
            let start = Date()
            repeat {
                let cycleStart = Date()
                openOnlyTestSchedule(app)
                app.buttons["편집"].tap()
                XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
                app.buttons["취소"].tap()
                let original = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "original-screenshot")).firstMatch
                reveal(original, in: app)
                XCTAssertTrue(original.waitForExistence(timeout: 10))
                app.navigationBars["일정"].buttons["홈"].tap()
                XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 8))
                app.buttons["설정"].tap()
                XCTAssertTrue(app.buttons["완료"].waitForExistence(timeout: 8))
                app.buttons["완료"].tap()
                if invocation > 1 {
                    measuredCycles += 1
                    measuredCycleSeconds.append(Date().timeIntervalSince(cycleStart))
                    print("[Task38 USB UI workload] cycles=\(measuredCycles) elapsed=\(Date().timeIntervalSince(start))")
                }
            } while Date().timeIntervalSince(start) < duration
        }
        attach(app, name: "USB real Home after ten minute local-image UI workload")
        let sorted = measuredCycleSeconds.sorted()
        print("[Task38 USB UI workload] measuredCycles=\(measuredCycles) cycleMedianSeconds=\(sorted[sorted.count / 2]) cycleMaximumSeconds=\(sorted.last ?? 0); timings include XCTest queries and idle waits; no cloud/network workload")
    }

    func testUSBAddSmallWidgetAndTapCard() throws {
        try requireTestPhone()
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !(springboard.buttons["편집"].exists && springboard.buttons["완료"].exists) {
            let icon = springboard.icons["SnapSchedule"]
            XCTAssertTrue(icon.waitForExistence(timeout: 8))
            for _ in 0..<4 {
                if icon.isHittable { break }
                springboard.swipeLeft()
            }
            XCTAssertTrue(icon.isHittable)
            icon.press(forDuration: 1.3)
            let editHome = springboard.buttons["홈 화면 편집"]
            XCTAssertTrue(editHome.waitForExistence(timeout: 5))
            editHome.tap()
        }
        XCTAssertTrue(springboard.buttons["편집"].waitForExistence(timeout: 5))
        springboard.buttons["편집"].tap()
        XCTAssertTrue(springboard.buttons["위젯 추가"].waitForExistence(timeout: 5))
        springboard.buttons["위젯 추가"].tap()
        let search = springboard.searchFields.firstMatch.exists ? springboard.searchFields.firstMatch : springboard.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("SnapSchedule")
        if springboard.keyboards.buttons["검색"].exists { springboard.keyboards.buttons["검색"].tap() }
        let entry = springboard.cells["SnapSchedule"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(entry.frame.width, 0)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = springboard.buttons["위젯 추가"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        attach(springboard, name: "USB actual small Widget gallery preview")
        add.tap()
        if springboard.buttons["완료"].waitForExistence(timeout: 5) { springboard.buttons["완료"].tap() }
        let card = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Task38 테스트")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        attach(springboard, name: "USB actual installed small Widget with registered schedule")
        card.tap()
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 12))
        attach(app, name: "USB Widget card direct tap opens actual matching schedule")
        print("[Task38 USB UI] small Widget installed through OS; registered card directly tapped; matching real schedule detail observed")
    }

    func testUSBInspectLargerTextSliderBaseline() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        let larger = settings.staticTexts["더 큰 텍스트"]
        reveal(larger, in: settings)
        larger.tap()
        XCTAssertTrue(settings.sliders.firstMatch.waitForExistence(timeout: 8))
        attach(settings, name: "USB actual larger text slider and baseline category")
        print("[Task38 USB UI] larger text slider: " + settings.sliders.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        print("[Task38 USB UI] larger text switches: " + settings.switches.allElementsBoundByIndex.map { $0.label + "=" + String(describing: $0.value) }.joined(separator: ";"))
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").activate()
    }

    func testUSBCalendarAddOnlyRetry() throws {
        try requireTestPhone()
        guard ProcessInfo.processInfo.environment["TASK38_CALENDAR_GRANT_CONFIRMED"] == "1" else {
            throw XCTSkip("New Calendar permission requires action-time user confirmation before this phase")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openAppPermissions(app)
        settings.staticTexts["캘린더"].tap()
        attach(settings, name: "USB actual Calendar permission choices after denial")
        let addOnly = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "이벤트 추가")).firstMatch
        XCTAssertTrue(addOnly.waitForExistence(timeout: 8), "Grant only the requested Calendar write permission")
        addOnly.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if settings.alerts.firstMatch.exists {
            let allow = settings.alerts.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "허용", "안"))
            XCTAssertEqual(allow.count, 1)
            allow.firstMatch.tap()
        } else if springboard.alerts.firstMatch.exists {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "허용", "안"))
            XCTAssertEqual(allow.count, 1)
            allow.firstMatch.tap()
        }
        app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.buttons["다시 시도"].waitForExistence(timeout: 8))
        app.buttons["다시 시도"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        attach(app, name: "USB actual Calendar retry result with local schedule retained")
        XCTAssertTrue(app.alerts.staticTexts["캘린더에 추가됨"].exists, "Actual Calendar write must succeed before counting export passed")
        app.alerts.buttons["확인"].tap()
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.staticTexts["캘린더에 추가됨"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual Calendar success persisted after new process")
        print("[Task38 USB UI] Calendar add-only authorization and explicit retry succeeded; local export success retained across process; account UI inspection still separate")
    }

    func testUSBLargestSystemTextAndContrast() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        let contrast = settings.switches["대비 증가"]
        XCTAssertEqual(contrast.value as? String, "0")
        let larger = settings.staticTexts["더 큰 텍스트"]
        reveal(larger, in: settings)
        larger.tap()
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        let baselineValue = slider.value as? String ?? ""
        print("[Task38 USB UI] text baseline slider=\(baselineValue), switch=\(String(describing: settings.switches.firstMatch.value))")
        guard baselineValue.hasSuffix("%"), let percent = Double(baselineValue.dropLast()), (0...100).contains(percent) else {
            throw XCTSkip("Cannot restore unrecognized OS text slider baseline; no display change made")
        }
        let baselineLarger = settings.switches.firstMatch.value as? String == "1"
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer {
            settings.activate()
            if settings.navigationBars["디스플레이 및 텍스트 크기"].exists {
                if settings.switches["대비 증가"].exists { setSwitch(settings.switches["대비 증가"], to: false) }
                let largerRow = settings.buttons["LARGER_TEXT"]
                if largerRow.exists { revealFromTop(largerRow, in: settings); largerRow.tap() }
            }
            if slider.exists {
                setSwitch(settings.switches.firstMatch, to: baselineLarger)
                slider.adjust(toNormalizedSliderPosition: CGFloat(percent / 100))
                attach(settings, name: "USB OS text size baseline restored")
            }
            app.activate()
        }
        setSwitch(settings.switches.firstMatch, to: true)
        slider.adjust(toNormalizedSliderPosition: 1)
        attach(settings, name: "USB actual OS largest accessibility text selected")
        settings.navigationBars.buttons.firstMatch.tap()
        reveal(contrast, in: settings)
        setSwitch(contrast, to: true)
        attach(settings, name: "USB actual OS increased contrast selected")
        app.launch()
        attach(app, name: "USB actual Home with largest OS text and increased contrast")
        openOnlyTestSchedule(app)
        attach(app, name: "USB actual schedule with largest OS text and increased contrast")
        app.buttons["편집"].tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual editor with largest OS text and increased contrast")
        app.buttons["취소"].tap()
        app.navigationBars["일정"].buttons["홈"].tap()
        app.buttons["설정"].tap()
        attach(app, name: "USB actual app Settings with largest OS text and increased contrast")
        app.buttons["완료"].tap()
        print("[Task38 USB UI] OS largest text and increased contrast actually selected; Home/detail/editor/Settings operated; restore baseline in defer")
    }

    func testUSBSystemReduceMotionAndRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        let motion = settings.staticTexts["동작"]
        reveal(motion, in: settings)
        motion.tap()
        let reduce = settings.switches["동작 줄이기"]
        XCTAssertTrue(reduce.waitForExistence(timeout: 8))
        let baseline = reduce.value as? String == "1"
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer {
            settings.activate()
            if reduce.exists { setSwitch(reduce, to: baseline) }
            attach(settings, name: "USB actual OS Reduce Motion baseline restored")
            app.activate()
        }
        setSwitch(reduce, to: true)
        attach(settings, name: "USB actual OS Reduce Motion enabled")
        app.launch()
        attach(app, name: "USB actual Home with OS Reduce Motion")
        openOnlyTestSchedule(app)
        app.buttons["편집"].tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual editor with OS Reduce Motion")
        app.buttons["취소"].tap()
        print("[Task38 USB UI] actual OS Reduce Motion enabled; Home/detail/editor navigation operated; original toggle restored")
    }

    func testUSBRestoreTextBaselineAfterSystemNotice() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notice = springboard.alerts.firstMatch
        if notice.waitForExistence(timeout: 3) {
            XCTAssertTrue(notice.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "손쉬운 사용")).firstMatch.exists)
            notice.buttons["허용 안 함"].tap()
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        if !settings.navigationBars["디스플레이 및 텍스트 크기"].exists {
            let display = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "디스플레이 및 텍스트 크기")).firstMatch
            reveal(display, in: settings)
            display.tap()
        }
        let larger = settings.buttons["LARGER_TEXT"]
        XCTAssertTrue(larger.waitForExistence(timeout: 8))
        larger.tap()
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        setSwitch(settings.switches.firstMatch, to: false)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(slider.value as? String, "50%")
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "0")
        attach(settings, name: "USB actual OS original 50 percent text baseline restored")
        print("[Task38 USB UI] unexpected Accessibility New Features notification prompt denied; original larger-text Off and text slider 50% restored")
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").launch()
    }

    func testUSBContinueSmallWidgetFromSearchCell() throws {
        try requireTestPhone()
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cell = springboard.cells["SnapSchedule"]
        XCTAssertTrue(cell.waitForExistence(timeout: 8))
        XCTAssertTrue(cell.isHittable)
        cell.tap()
        let add = springboard.buttons["위젯 추가"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        attach(springboard, name: "USB actual small Widget gallery before installation")
        add.tap()
        if springboard.buttons["완료"].waitForExistence(timeout: 5) { springboard.buttons["완료"].tap() }
        let card = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Task38 테스트")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        attach(springboard, name: "USB actual installed small Widget")
        card.tap()
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 12))
        attach(app, name: "USB actual Widget direct card tap destination")
        print("[Task38 USB UI] OS Widget search result Cell used; small Widget installed; direct card tap reached registered test schedule")
    }

    func testUSBLargeTextOnlyWithDirectRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        settings.buttons["LARGER_TEXT"].tap()
        let slider = settings.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        XCTAssertEqual(slider.value as? String, "50%")
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "0")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer {
            settings.activate()
            XCTAssertTrue(slider.waitForExistence(timeout: 8))
            setSwitch(settings.switches.firstMatch, to: false)
            slider.adjust(toNormalizedSliderPosition: 0.5)
            XCTAssertEqual(slider.value as? String, "50%")
            attach(settings, name: "USB OS text baseline restored directly from same panel")
            app.activate()
        }
        setSwitch(settings.switches.firstMatch, to: true)
        slider.adjust(toNormalizedSliderPosition: 1)
        attach(settings, name: "USB actual largest OS accessibility text selected")
        app.launch()
        attach(app, name: "USB actual largest OS text Home")
        openOnlyTestSchedule(app)
        attach(app, name: "USB actual largest OS text schedule detail")
        app.buttons["편집"].tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual largest OS text schedule editor")
        app.buttons["취소"].tap()
        print("[Task38 USB UI] actual largest OS text Home/detail/editor navigation; direct same-panel restore to Off/50%")
    }

    func testUSBContrastOnlyWithDirectRestore() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let accessibility = settings.staticTexts["손쉬운 사용"]
        revealFromTop(accessibility, in: settings)
        accessibility.tap()
        settings.staticTexts["디스플레이 및 텍스트 크기"].tap()
        let contrast = settings.switches["대비 증가"]
        reveal(contrast, in: settings)
        XCTAssertEqual(contrast.value as? String, "0")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        defer {
            settings.activate()
            XCTAssertTrue(contrast.waitForExistence(timeout: 8))
            setSwitch(contrast, to: false)
            attach(settings, name: "USB OS contrast baseline restored")
            app.activate()
        }
        setSwitch(contrast, to: true)
        attach(settings, name: "USB actual OS increased contrast selected")
        app.launch()
        attach(app, name: "USB actual Home with increased OS contrast")
        openOnlyTestSchedule(app)
        app.buttons["편집"].tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual editor with increased OS contrast")
        app.buttons["취소"].tap()
        print("[Task38 USB UI] actual OS increased contrast, Home/detail/editor navigation, baseline Off restored")
    }

    func testUSBRestoreLightAfterTransition() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        openSystemRoot(settings)
        let display = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "밝기")).firstMatch
        revealFromTop(display, in: settings)
        display.tap()
        let light = settings.buttons["라이트 모드"]
        XCTAssertTrue(light.waitForExistence(timeout: 8))
        print("[Task38 USB UI] appearance frames light=\(light.frame), dark=\(settings.buttons["다크 모드"].frame)")
        light.tap()
        // Observe after the OS transition, before leaving Preferences.
        XCTAssertTrue(settings.switches["자동"].waitForExistence(timeout: 8))
        attach(settings, name: "USB OS Light selection after foreground transition settled")
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual Home after observed OS Light selection")
    }

    func testUSBInspectCalendarGrantChoiceOnly() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        let settings = openAppPermissions(app)
        settings.staticTexts["캘린더"].tap()
        XCTAssertTrue(settings.navigationBars["캘린더"].waitForExistence(timeout: 8))
        attach(settings, name: "USB actual Calendar permission choices without granting")
        print("[Task38 USB UI] Calendar permission cells: " + settings.cells.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        let addOnly = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "이벤트 추가")).firstMatch
        XCTAssertTrue(addOnly.waitForExistence(timeout: 8))
        attach(settings, name: "USB actual Calendar add-only option ready for user approval")
        print("[Task38 USB UI] Calendar add-only choice visible; no grant and no Calendar write performed")
        app.activate()
    }

    func testUSBInspectNotificationRescheduleControls() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyTestSchedule(app)
        app.buttons["편집"].tap()
        XCTAssertTrue(app.buttons["날짜"].waitForExistence(timeout: 8))
        app.buttons["날짜"].tap()
        XCTAssertTrue(app.navigationBars["날짜 선택"].waitForExistence(timeout: 8))
        attach(app, name: "USB actual date controls before reminder reschedule; no save")
        print("[Task38 USB UI reminder controls] date: " + app.datePickers.debugDescription)
        app.buttons["완료"].tap()
        let timePicker = app.datePickers.firstMatch
        XCTAssertTrue(timePicker.waitForExistence(timeout: 8))
        timePicker.tap()
        attach(app, name: "USB actual time controls before reminder reschedule; no save")
        print("[Task38 USB UI reminder controls] time: " + app.debugDescription)
        // A new launch discards this unsaved inspection draft.
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
    }

    func testUSBRealPlannerBannerAndDirectTap() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        openOnlyTestSchedule(app)
        app.buttons["편집"].tap()
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        XCTAssertEqual(app.buttons["날짜"].value as? String, "2026년 10월 5일")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "US/Pacific")!
        let target = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(240))
        XCTAssertEqual(target.year, 2026)
        XCTAssertEqual(target.month, 10)
        XCTAssertEqual(target.day, 4, "Only the observed test-date window is authorized")
        selectTestDate(day: 4, in: app)
        selectTestTime(hour: target.hour!, minute: target.minute!, in: app)
        XCTAssertEqual(app.switches["당일 알림"].value as? String, "1")
        saveTestSchedule(app)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 4일"].waitForExistence(timeout: 8))
        let expectedTime = "시간, \(target.hour! < 12 ? "오전" : "오후") \(target.hour! % 12 == 0 ? 12 : target.hour! % 12):\(String(format: "%02d", target.minute!))"
        XCTAssertTrue(app.staticTexts[expectedTime].exists, "Read the actual saved schedule after changing native wheels")
        attach(app, name: "USB actual test schedule temporarily rescheduled for real planner banner")
        print("[Task38 USB UI real banner] target US/Pacific 2026-10-04 \(target.hour!):\(target.minute!) via actual editor/planner; no synthetic notification")
        app.navigationBars["일정"].buttons["홈"].tap()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["일정"].exists, "Begin notification routing from Home, not an already-open detail")
        attach(app, name: "USB actual Home before background planner notification routing")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let title = springboard.staticTexts["Task38 테스트"]
        let bannerAppeared = title.waitForExistence(timeout: 270)
        var deliveredCard = bannerAppeared
        var reachedDetail = false
        if !bannerAppeared {
            attach(springboard, name: "USB actual OS after planner deadline without observed test banner")
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
            top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.8)))
            deliveredCard = title.waitForExistence(timeout: 10)
        }
        if deliveredCard {
            attach(springboard, name: bannerAppeared ? "USB actual planner banner before direct tap" : "USB actual planner Notification Center card before direct tap; banner unverified")
            if title.isHittable { title.tap() }
            else { title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            reachedDetail = app.navigationBars["일정"].waitForExistence(timeout: 20)
            if reachedDetail { attach(app, name: "USB actual schedule detail after direct planner notification tap") }
        }
        // Restore before asserting delivery, so a missing OS banner does not strand the fixture.
        restoreOriginalTestSchedule(app)
        XCTAssertTrue(deliveredCard, "Actual OS delivery must be observed; scheduled queue alone is insufficient")
        XCTAssertTrue(reachedDetail, "Direct notification tap must open the schedule detail")
        print("[Task38 USB UI real banner] bannerObserved=\(bannerAppeared) actualDeliveredCard=\(deliveredCard) directTapDetail=\(reachedDetail); original October5 16:00 fixture restored; a silent Center card does not prove banner delivery")
    }

    func testUSBZRestoreOriginalReminderFixture() throws {
        try requireTestPhone()
        continueAfterFailure = false
        restoreOriginalTestSchedule(XCUIApplication(bundleIdentifier: "com.example.SnapSchedule"))
    }

    func testUSBInspectExportedCalendarAccount() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let calendarApp = XCUIApplication(bundleIdentifier: "com.apple.mobilecal")
        calendarApp.launch()
        if calendarApp.buttons["계속"].exists { calendarApp.buttons["계속"].tap() }
        let search = calendarApp.buttons["검색"]
        guard search.waitForExistence(timeout: 8) else {
            attach(calendarApp, name: "USB actual Calendar initial screen; account event not yet inspected")
            print("[Task38 USB Calendar UI] initial controls: " + calendarApp.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
            throw XCTSkip("Native Calendar onboarding/search requires an observed control before inspecting the exported event")
        }
        // iOS26 searchbar-button was observed at a nonzero frame, but a
        // synthesized semantic tap left Calendar on its day screen.
        XCTAssertTrue(search.isHittable)
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let field = calendarApp.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        if let value = field.value as? String, !value.isEmpty && value != "검색" {
            XCTAssertEqual(field.buttons.count, 1)
            field.buttons.firstMatch.tap()
        }
        field.tap()
        field.typeText("Task38 테스트")
        let title = calendarApp.staticTexts["Task38 테스트"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(calendarApp.staticTexts.matching(identifier: "Task38 테스트").count, 1)
        attach(calendarApp, name: "USB actual Calendar search result for the single approved test event")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(calendarApp.buttons["편집"].waitForExistence(timeout: 8))
        attach(calendarApp, name: "USB actual Calendar account test event detail")
        print("[Task38 USB Calendar UI] approved event detail: " + calendarApp.debugDescription)
        calendarApp.buttons["편집"].tap()
        XCTAssertTrue(calendarApp.buttons["취소"].waitForExistence(timeout: 8))
        XCTAssertTrue(calendarApp.textFields.matching(NSPredicate(format: "value == %@", "Task38 테스트")).firstMatch.exists)
        attach(calendarApp, name: "USB actual Calendar test event date duration and alarm editor; inspection only")
        print("[Task38 USB Calendar UI] approved event editor inspection: " + calendarApp.debugDescription)
        calendarApp.buttons["취소"].tap()
        XCUIApplication(bundleIdentifier: "com.example.SnapSchedule").launch()
    }

    func testUSBDeliveredNotificationCenterCardColdTap() throws {
        try requireTestPhone()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        app.launch()
        XCTAssertTrue(app.navigationBars["홈"].waitForExistence(timeout: 8))
        app.terminate()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.8)))
        let title = springboard.staticTexts["Task38 테스트"]
        guard title.waitForExistence(timeout: 10) else {
            app.launch()
            throw XCTSkip("No retained actual test notification card; no synthetic replacement was scheduled")
        }
        attach(springboard, name: "USB retained actual planner Notification Center card before cold direct tap")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The actual OS notification touch must launch the app")
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB actual notification cold tap showing the restored current schedule")
        print("[Task38 USB UI real card] cold notification tap launched matching detail; old delivered card resolved the current restored October5 16:00 schedule; no synthetic request")
    }

    private func selectTestDate(day: Int, in app: XCUIApplication) {
        app.buttons["날짜"].tap()
        XCTAssertTrue(app.navigationBars["날짜 선택"].waitForExistence(timeout: 8))
        let days = app.datePickers.firstMatch.buttons.matching(NSPredicate(format: "label == %@ OR label MATCHES %@", String(day), ".*10월 *\(day)일.*"))
        print("[Task38 USB UI real banner] observed date button labels: " + app.datePickers.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: ";"))
        XCTAssertEqual(days.count, 1)
        days.firstMatch.tap()
        app.buttons["완료"].tap()
        XCTAssertEqual(app.buttons["날짜"].value as? String, "2026년 10월 \(day)일")
    }

    private func selectTestTime(hour: Int, minute: Int, in app: XCUIApplication) {
        app.datePickers.firstMatch.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(app.pickerWheels.count, 3)
        // Native wheels carry across minute/hour boundaries. Set meridiem
        // last, after both numerical wheels, and verify all three settled values.
        app.pickerWheels.element(boundBy: 2).adjust(toPickerWheelValue: String(format: "%02d", minute))
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "\(hour % 12 == 0 ? 12 : hour % 12)")
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: hour < 12 ? "오전" : "오후")
        let meridiemSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", hour < 12 ? "오전" : "오후"), object: app.pickerWheels.element(boundBy: 0))
        XCTAssertEqual(XCTWaiter.wait(for: [meridiemSettled], timeout: 5), .completed)
        let minuteSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", String(format: "%02d분", minute)), object: app.pickerWheels.element(boundBy: 2))
        XCTAssertEqual(XCTWaiter.wait(for: [minuteSettled], timeout: 5), .completed)
        XCTAssertEqual(app.pickerWheels.element(boundBy: 0).value as? String, hour < 12 ? "오전" : "오후")
        XCTAssertEqual(app.pickerWheels.element(boundBy: 1).value as? String, "\(hour % 12 == 0 ? 12 : hour % 12)시")
        XCTAssertEqual(app.pickerWheels.element(boundBy: 2).value as? String, String(format: "%02d분", minute))
        app.buttons["팝업 닫기"].tap()
        XCTAssertFalse(app.pickerWheels.firstMatch.exists)
    }

    private func saveTestSchedule(_ app: XCUIApplication) {
        app.navigationBars["일정 편집"].buttons["저장"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["일정 편집"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 12), .completed)
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.navigationBars["일정 편집"].exists)
    }

    private func restoreOriginalTestSchedule(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        if app.staticTexts["날짜, 2026년 10월 5일"].exists && app.staticTexts["시간, 오후 4:00"].exists {
            attach(app, name: "USB original reminder fixture already intact before restoration")
            return
        }
        app.buttons["편집"].tap()
        XCTAssertEqual(app.textFields["제목"].value as? String, "Task38 테스트")
        selectTestDate(day: 5, in: app)
        selectTestTime(hour: 16, minute: 0, in: app)
        saveTestSchedule(app)
        app.terminate()
        app.launch()
        openOnlyTestSchedule(app)
        XCTAssertTrue(app.staticTexts["날짜, 2026년 10월 5일"].exists)
        XCTAssertTrue(app.staticTexts["시간, 오후 4:00"].exists)
        attach(app, name: "USB original reminder fixture restored after actual banner phase")
    }

    private func openNotificationSettings(_ app: XCUIApplication) -> XCUIApplication {
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 20))
        app.buttons["설정"].tap()
        XCTAssertTrue(app.buttons["알림 설정 열기"].waitForExistence(timeout: 8))
        app.buttons["알림 설정 열기"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(settings.switches["알림 허용"].waitForExistence(timeout: 8))
        return settings
    }

    private func openOnlyCandidate(_ app: XCUIApplication) {
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "후보 검수하기")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        review.tap()
        XCTAssertTrue(app.navigationBars["후보"].waitForExistence(timeout: 8))
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-detail-"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(cards.count, 1)
        let image = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "candidate-image-")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        XCTAssertTrue(image.isHittable)
        image.tap()
        XCTAssertTrue(app.textFields["제목"].waitForExistence(timeout: 8))
    }

    private func openOnlyTestSchedule(_ app: XCUIApplication) {
        let schedules = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "schedule-detail-", "Task38 테스트"))
        reveal(schedules.firstMatch, in: app)
        // The selected-day and upcoming sections can show the same schedule twice.
        // Require one schedule identity, rather than one visual representation.
        XCTAssertEqual(Set(schedules.allElementsBoundByIndex.map { $0.identifier }).count, 1)
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "schedule-original-", "Task38 테스트")).firstMatch
        if original.exists && original.isHittable {
            // The actual selected-day source image is loaded before touching this stable control.
            // The row was observed to stay on Home after a synthesized tap in the failed phase.
            original.tap()
        } else {
            schedules.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["일정"].waitForExistence(timeout: 8))
    }

    private func replace(_ field: XCUIElement, with value: String) {
        let app = XCUIApplication(bundleIdentifier: "com.example.SnapSchedule")
        field.tap()
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["전체 선택"]
        let selectAllButton = app.buttons["전체 선택"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
        else {
            XCTAssertTrue(selectAllButton.waitForExistence(timeout: 2), "Select All must be visible before replacing known test text")
            selectAllButton.tap()
        }
        field.typeText(value)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected control must be reachable by actual scrolling")
    }

    private func requireTestPhone(_ caller: String = #function) throws {
        let allowed = ProcessInfo.processInfo.environment["TASK38_UI_CASES", default: ""].split(separator: ",").map(String.init)
        guard allowed.contains(caller.replacingOccurrences(of: "()", with: "")) else {
            throw XCTSkip("Stateful Task38 phases require an explicit per-case invocation; default Scheme runs the navigation probe only")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Task38 physical test-phone UI only")
        #else
        guard ProcessInfo.processInfo.environment["TASK38_UI_VALIDATION"] == "1",
              ProcessInfo.processInfo.environment["TASK38_UI_DEVICE_UDID"] == "00000000-0000000000000000" else {
            throw XCTSkip("Explicit Task38 test-phone invocation required")
        }
        #endif
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
