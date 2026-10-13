import Photos
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit
import XCTest
import GoogleMobileAds
@testable import SnapSchedule

/// Real product views hosted in the Simulator. Fixtures never touch the user's photo library or store.
@MainActor
final class Task421DesignPresentationTests: XCTestCase {
    func testAddedDateManualDateTimeZoneAndAllDayControlsKeepFirstRowIndependent() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
        context.autosaveEnabled = false
        let source = ScheduleCandidate(sourceAssetIdentifier: "manual-batch-photo", sourceCandidateKey: "one",
            title: String(localized: "Appointment"), date: CalendarDate(year: 2026, month: 10, day: 18),
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")
        context.insert(source); try context.save()
        let navigation = AppTabNavigation()
        let image = try XCTUnwrap(sourceImage().pngData())
        let host = UIHostingController(rootView: NavigationStack {
            CandidateDetailView(candidate: source, navigation: navigation).navigationTitle(String(localized: "Candidate"))
        }.modelContainer(container).environment(\.screenshotPreviewFactory, { id in
            ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: image, orientation: .up) }
        }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }; let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 428, height: 926); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; navigation.candidateWillLeave = nil; previous?.makeKeyAndVisible() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(350)); host.view.layoutIfNeeded() }
        func press(_ id: String) async throws {
            if let object = PresentationAutomationScope.objects(in: window).first(where: { pairingIdentifier($0) == id && $0.isAccessibilityElement }) {
                XCTAssertTrue(activateReviewButton(object, in: host.view)); try await settle(); return
            }
            let scroll = firstScroll(host.view)
            scroll?.setContentOffset(CGPoint(x: 0, y: -(scroll?.adjustedContentInset.top ?? 0)), animated: false)
            for step in 0..<30 {
                try await settle()
                if let object = PresentationAutomationScope.objects(in: window).first(where: { pairingIdentifier($0) == id && $0.isAccessibilityElement }) {
                    XCTAssertTrue(activateReviewButton(object, in: host.view)); try await settle(); return
                }
                if let scroll { scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step + 1) * 150), animated: false) }
            }
            throw NSError(domain: "MissingManualDateControl-" + id, code: 1)
        }
        try await settle(); try await press("candidate-add-date")
        try await press("candidate-choose-date-2")
        let datePicker = try XCTUnwrap(descendantsForResponsive(window).compactMap { $0 as? UIDatePicker }
            .first { $0.datePickerMode == .date && $0.preferredDatePickerStyle == .inline })
        datePicker.date = try XCTUnwrap(CalendarDate(year: 2026, month: 10, day: 20).foundationDate())
        datePicker.sendActions(for: .valueChanged); try await settle()
        attach(window, name: "manual-batch-date-\(Locale.current.identifier)")
        try await press("candidate-date-save")
        try await press("candidate-set-time-2")
        let input = try XCTUnwrap(descendantsForResponsive(window).compactMap { $0 as? UITextField }
            .first { $0.placeholder == String(localized: "Time (HH:mm)") })
        XCTAssertEqual(input.text, "", "An added row must start without an invented time")
        input.text = "09:00"; input.sendActions(for: .editingChanged); try await settle()
        attach(window, name: "manual-batch-time-\(Locale.current.identifier)")
        try await press("candidate-time-save")
        try await press("candidate-time-zone-2")
        let zone = try XCTUnwrap(PresentationAutomationScope.objects(in: window).first {
            $0.accessibilityLabel == "Asia/Tokyo" && $0.isAccessibilityElement
        })
        XCTAssertTrue(activateReviewButton(zone, in: host.view)); try await settle()
        XCTAssertEqual(navigation.candidateWillLeave?(), true)
        XCTAssertEqual(source.dateEntries[0].date, CalendarDate(year: 2026, month: 10, day: 18))
        XCTAssertEqual(source.dateEntries[0].time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(source.dateEntries[0].timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(source.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(source.dateEntries[1].time, ClockTime(hour: 9, minute: 0))
        XCTAssertEqual(source.dateEntries[1].timeZoneIdentifier, "Asia/Tokyo")
        try await press("candidate-remove-time-2")
        XCTAssertEqual(navigation.candidateWillLeave?(), true)
        XCTAssertNil(source.dateEntries[1].time)
        XCTAssertEqual(source.dateEntries[1].timeZoneIdentifier, "Asia/Tokyo")
        attach(host.view, name: "manual-batch-all-day-\(Locale.current.identifier)")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }
    func testPhotoBatchEditorActionsAutosaveRetryRestoreAndOneRegistration() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
        context.autosaveEnabled = false
        let source = ScheduleCandidate(sourceAssetIdentifier: "batch-ui-photo", sourceCandidateKey: "one",
            title: String(localized: "Appointment"), date: CalendarDate(year: 2026, month: 10, day: 18),
            time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")
        source.recognizedDateOptions = [
            CandidateDateEntry(date: source.date, time: source.time, timeZoneIdentifier: "Asia/Seoul"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20), time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "Asia/Tokyo")
        ]
        context.insert(source); try context.save()
        let navigation = AppTabNavigation()
        var failSave = true
        let image = try XCTUnwrap(sourceImage().pngData())
        func screen() -> AnyView {
            AnyView(NavigationStack {
                CandidateDetailView(candidate: source,
                    notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission request"); return false }),
                    notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()),
                    navigation: navigation, draftSave: { context in
                        if failSave { throw NSError(domain: "batch-save", code: 1) }; try context.save()
                    }).navigationTitle(String(localized: "Candidate"))
            }.modelContainer(container).id(UUID())
            .environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: image, orientation: .up) } }))
        }
        let host = UIHostingController(rootView: screen())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; navigation.candidateWillLeave = nil; previous?.makeKeyAndVisible() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(350)); host.view.layoutIfNeeded() }
        func control(_ identifier: String) async throws -> NSObject {
            let scroll = firstScroll(host.view)
            scroll?.setContentOffset(CGPoint(x: 0, y: -(scroll?.adjustedContentInset.top ?? 0)), animated: false)
            for step in 0..<30 {
                try await settle()
                if let object = PresentationAutomationScope.objects(in: window).first(where: {
                    pairingIdentifier($0) == identifier && $0.isAccessibilityElement
                }) { return object }
                if let scroll {
                    let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x: 0, y: min(CGFloat(step + 1) * 130, maximum)), animated: false)
                }
            }
            XCTFail("Missing control \(identifier)")
            throw NSError(domain: "MissingBatchControl", code: 1)
        }
        func press(_ identifier: String) async throws {
            let object = try await control(identifier)
            XCTAssertTrue(activateReviewButton(object, in: host.view))
        }
        try await settle()
        try await press("candidate-add-date")
        try await settle()
        attach(host.view, name: "photo-batch-auto-added-\(Locale.current.identifier)")
        XCTAssertEqual(navigation.candidateWillLeave?(), false, "Failure must keep the editor and both inputs")
        XCTAssertEqual(source.dateEntries.count, 1)
        failSave = false
        XCTAssertEqual(navigation.candidateWillLeave?(), true)
        XCTAssertEqual(source.dateEntries.count, 2)
        XCTAssertEqual(source.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(source.dateEntries[1].time, ClockTime(hour: 9, minute: 0))
        XCTAssertEqual(source.dateEntries[1].timeZoneIdentifier, "Asia/Tokyo")
        host.rootView = screen(); try await settle()
        try await press("candidate-add-date"); try await settle()
        try await press("candidate-remove-date-3"); try await settle()
        XCTAssertEqual(navigation.candidateWillLeave?(), true)
        XCTAssertEqual(source.dateEntries.count, 2)
        host.rootView = screen(); try await settle()
        let register = try await control("candidate-register")
        XCTAssertFalse(register.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(activateReviewButton(register, in: host.view))
        _ = activateReviewButton(register, in: host.view) // A repeated action must not create a second batch.
        try await settle()
        let schedules = try context.fetch(FetchDescriptor<Schedule>()).sorted { $0.date.day < $1.date.day }
        XCTAssertEqual(schedules.count, 2)
        XCTAssertEqual(schedules.map(\.date), [CalendarDate(year: 2026, month: 10, day: 18), CalendarDate(year: 2026, month: 10, day: 20)])
        XCTAssertEqual(schedules.map(\.time), [ClockTime(hour: 14, minute: 0), ClockTime(hour: 9, minute: 0)])
        XCTAssertEqual(schedules.map(\.timeZoneIdentifier), ["Asia/Seoul", "Asia/Tokyo"])
        XCTAssertEqual(Set(schedules.map(\.sourceCandidateID)), [source.id])
        XCTAssertEqual(source.registeredScheduleIDs.count, 2)
        XCTAssertEqual(source.reviewStatus, .registered)
        XCTAssertEqual(CandidateReviewSummary(candidates: [source]).pendingCount, 0)
        attach(host.view, name: "photo-batch-registered-\(Locale.current.identifier)")
    }

    func testPhotoBatchLayoutsAndLocalizedControlsOnSmallLargeAndLandscapeScreens() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let source = ScheduleCandidate(sourceAssetIdentifier: "batch-layout-photo", sourceCandidateKey: "one",
            title: String(localized: "Appointment"), date: CalendarDate(year: 2026, month: 10, day: 18))
        source.dateEntries = [
            CandidateDateEntry(date: source.date, time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 20), time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "America/Los_Angeles"),
            CandidateDateEntry(date: CalendarDate(year: 2026, month: 10, day: 22), timeZoneIdentifier: "Asia/Tokyo")
        ]
        container.mainContext.insert(source); try container.mainContext.save()
        let image = try XCTUnwrap(sourceImage().pngData())
        for (name, size, large) in [("small", CGSize(width: 375, height: 667), false),
                                   ("plus", CGSize(width: 428, height: 926), false),
                                   ("large-text", CGSize(width: 375, height: 667), true),
                                   ("landscape", CGSize(width: 812, height: 375), false)] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let host = UIHostingController(rootView: NavigationStack {
                CandidateDetailView(candidate: source).navigationTitle(String(localized: "Candidate"))
            }.modelContainer(container).environment(\.dynamicTypeSize, large ? .accessibility5 : .large)
            .environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: image, orientation: .up) } }))
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(400))
            attach(host.view, name: "photo-batch-\(Locale.current.identifier)-\(name)-top")
            let scroll = try XCTUnwrap(firstScroll(host.view))
            var labels: [String] = []
            var captured = Set<String>()
            for step in 0..<55 {
                labels += PresentationAutomationScope.objects(in: host.view).compactMap(\.accessibilityLabel)
                for id in ["candidate-time-zone-2", "candidate-time-zone-3", "candidate-add-date", "candidate-date-count"] where !captured.contains(id) {
                    if PresentationAutomationScope.objects(in: host.view).contains(where: { pairingIdentifier($0) == id && $0.isAccessibilityElement }) {
                        attach(host.view, name: "photo-batch-\(Locale.current.identifier)-\(name)-\(id)")
                        captured.insert(id)
                    }
                }
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let next = min(CGFloat(step + 1) * 180, maximum)
                scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                if next == maximum { break }
            }
            for key in ["Add date +", "Remove date", "All-day", "Time zone"] {
                XCTAssertTrue(labels.contains { $0.contains(String(localized: String.LocalizationValue(key))) }, "Missing localized \(key) on \(name): \(labels)")
            }
            XCTAssertTrue(captured.contains("candidate-date-count"))
            XCTAssertFalse(labels.contains(String(localized: "Confirm the inferred time zone")))
            attach(host.view, name: "photo-batch-\(Locale.current.identifier)-\(name)-original")
        }
    }
    func testContestDeadlineGalleryAndIndividualRegistrationInCurrentLanguage() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
        context.autosaveEnabled = false
        let queue = ScanQueue(context: context)
        let titles = ["7th Da-Ho Award Short Film Competition", language == "ja" ? "LG 写真コンテスト" : language == "en" ? "LG Smile photo contest" : "LG 대국민 미소 사진 공모전"]
        let periods = ["2026-08-01 ~ 2027-01-15 D-100", "2026.09.23 - 10.18"]
        let suite = "ContestDeadlineScreens.\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        settings.reminderDayBefore = false; settings.reminderSameDay = false; settings.defaultExportToCalendar = false
        try queue.prepare(for: .authorized((0..<2).map { ScreenshotAssetMetadata(assetIdentifier: "contest-\($0)", creationDate: nil, pixelWidth: 2000, pixelHeight: 1000) }))
        let owner = try queue.beginExecution()
        for _ in 0..<2 {
            let scan = try XCTUnwrap(queue.claimNext(owner: owner))
            let index = scan.assetIdentifier == "contest-0" ? 0 : 1
            let fragments = [RecognizedTextFragment(text: titles[index], boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.04), confidence: 1), RecognizedTextFragment(text: periods[index], boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.04), confidence: 1)]
            let drafts = DateTimeParser().parse(fragments: fragments, captureDate: nil,
                analysisDate: Date(timeIntervalSince1970: 1791334800), timeZone: TimeZone(identifier: "Asia/Seoul")!)
            try CandidateCreationService(context: context, scanQueue: queue).completeAnalysis(scan, owner: owner, drafts: drafts,
                fragments: fragments, settings: settings, analysisVersion: "vision3-parser2-filter1")
        }
        let candidates = try context.fetch(FetchDescriptor<ScheduleCandidate>()).sorted { $0.sourceAssetIdentifier < $1.sourceAssetIdentifier }
        XCTAssertEqual(candidates.count, 2); XCTAssertEqual(CandidateReviewSummary(candidates: candidates).readyCount, 2)
        XCTAssertEqual(Set(candidates.map(\.sourceAssetIdentifier)).count, 2)
        XCTAssertEqual(candidates.map(\.date), [CalendarDate(year: 2027, month: 1, day: 15), CalendarDate(year: 2026, month: 10, day: 18)])
        let selection = CandidateSelectionState(); selection.synchronize(with: candidates)
        XCTAssertTrue(selection.dismissalCandidateIDs.isEmpty)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1800)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            ("SYNTHETIC CONTEST\n\n" + zip(titles, periods).map { $0 + "\n" + $1 }.joined(separator: "\n\n")).draw(in: CGRect(x: 60, y: 100, width: 1080, height: 1500), withAttributes: [.font: UIFont.systemFont(ofSize: 52), .foregroundColor: UIColor.black])
        }
        let data = try XCTUnwrap(image.pngData())
        let denied = NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission request"); return false })
        let notifications = NotificationScheduler(center: DesignNotificationCenter())
        for large in [false, true] {
            try await render(NavigationStack { CandidateListView(selectionState: selection, onOpenCandidate: { _ in }) }
                .modelContainer(container).environment(\.screenshotThumbnailFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) } }),
                name: "contest-candidate-gallery-\(language)-\(large ? "AX5" : "normal")", scheme: .light, large: large,
                size: large ? CGSize(width: 375, height: 667) : CGSize(width: 428, height: 926))
        }
        let candidate = try XCTUnwrap(candidates.first)
        let host = UIHostingController(rootView: NavigationStack { CandidateDetailView(candidate: candidate,
            notificationAuthorization: denied, notificationScheduler: notifications) }
            .modelContainer(container).environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) } }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }; let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 428, height: 926); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400)); attach(host.view, name: "contest-deadline-detail-\(language)")
        let register = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
        XCTAssertFalse(register.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(register.accessibilityActivate()); try await Task.sleep(for: .milliseconds(500))
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        XCTAssertEqual(schedules.count, 1, "One editor action registers only its own deadline")
        XCTAssertEqual(schedules.first?.date, CalendarDate(year: 2027, month: 1, day: 15))
        XCTAssertEqual(schedules.first?.title, titles[0]); XCTAssertEqual(candidates[1].reviewStatus, .pending)
        attach(host.view, name: "contest-deadline-registered-\(language)")
    }

    // Catches destructive selection inheriting registration defaults, wrong card routing,
    // and a confirmed batch accidentally including a later arrival.
    func testExplicitBatchSelectionStartsEmptyCancelsAndIgnoresOnlyChosenCandidates() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext; context.autosaveEnabled = false
        let first = ScheduleCandidate(sourceAssetIdentifier: "batch-photo", sourceCandidateKey: "first", title: "First", date: CalendarDate(year: 2026, month: 10, day: 8))
        let second = ScheduleCandidate(sourceAssetIdentifier: "batch-photo", sourceCandidateKey: "second", title: "Second", date: CalendarDate(year: 2026, month: 10, day: 9), reviewReasons: [.relativeDate])
        let survivor = ScheduleCandidate(sourceAssetIdentifier: "other-photo", sourceCandidateKey: "survivor", title: "Survivor", date: CalendarDate(year: 2026, month: 10, day: 10))
        let scan = ScreenshotScan(assetIdentifier: "batch-photo", status: .completed)
        [first, second, survivor].forEach { context.insert($0) }; context.insert(scan); try context.save()
        let selection = CandidateSelectionState(); var opened: [UUID] = []
        let host = UIHostingController(rootView: NavigationStack {
            CandidateListView(selectionState: selection, onOpenCandidate: { opened.append($0) })
        }.modelContainer(container).environment(\.screenshotThumbnailFactory, { id in
            let data = self.sourceImage().pngData()!
            return ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) }
        }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        func action(_ id: String, in view: UIView? = nil) throws -> NSObject {
            func find() -> NSObject? {
                PresentationAutomationScope.objects(in: view ?? host.view).first {
                    self.pairingIdentifier($0) == id && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)
                }
            }
            if let object = find() { return object }
            if view == nil, let scroll = firstScroll(host.view) {
                let top = -scroll.adjustedContentInset.top
                for step in 0..<20 {
                    scroll.setContentOffset(CGPoint(x: 0, y: top + CGFloat(step) * 120), animated: false)
                    settle(0.12)
                    if let object = find() { return object }
                }
            }
            print("Missing \(id): " + PresentationAutomationScope.objects(in: host.view).compactMap { object in
                self.pairingIdentifier(object).map { "\($0): \(type(of: object)) element=\(object.isAccessibilityElement) traits=\(object.accessibilityTraits.rawValue)" }
            }.joined(separator: "; "))
            return try XCTUnwrap(find(), "Missing action \(id)")
        }
        XCTAssertEqual(selection.selectedCandidateIDs, [first.id, survivor.id], "Registration defaults still exist")
        XCTAssertTrue(activateReviewButton(try action("candidate-selection-start"), in: host.view))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try action("candidate-dismiss-selected").accessibilityTraits.contains(.notEnabled), "Ignore mode must begin empty")
        attach(host.view, name: "batch-empty")
        XCTAssertTrue(try action("candidate-image-\(first.id)").accessibilityActivate())
        XCTAssertTrue(try action("candidate-image-\(second.id)").accessibilityActivate())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(opened.isEmpty, "Selection must not open an editor")
        XCTAssertTrue(try action("candidate-detail-\(first.id)").accessibilityTraits.contains(.selected))
        XCTAssertTrue(try action("candidate-detail-\(second.id)").accessibilityTraits.contains(.selected))
        XCTAssertFalse(try action("candidate-detail-\(survivor.id)").accessibilityTraits.contains(.selected))
        attach(host.view, name: "batch-two-selected")
        XCTAssertTrue(try action("candidate-dismiss-selected").accessibilityActivate())
        try await Task.sleep(for: .milliseconds(300))
        let dialog = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertTrue(PresentationAutomationScope.objects(in: dialog.view).compactMap(\.accessibilityLabel).joined().contains("2"), "Confirmed count must be visible")
        XCTAssertEqual(first.reviewStatus, .pending); XCTAssertEqual(second.reviewStatus, .pending)
        attach(window, name: "batch-count-confirmation")
        let cancel = try XCTUnwrap(PresentationAutomationScope.objects(in: dialog.view).first { $0.isAccessibilityElement && $0.accessibilityLabel == String(localized: "Cancel") })
        XCTAssertTrue(activateReviewButton(cancel, in: dialog.view)); try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try action("candidate-detail-\(first.id)").accessibilityTraits.contains(.selected), "Cancelling confirmation preserves selection")
        XCTAssertTrue(activateReviewButton(try action("candidate-selection-cancel"), in: host.view)); try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try action("candidate-image-\(survivor.id)").accessibilityActivate())
        XCTAssertEqual(opened, [survivor.id], "Normal mode keeps editor routing")
        XCTAssertTrue(activateReviewButton(try action("candidate-selection-start"), in: host.view)); try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try action("candidate-dismiss-selected").accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(try action("candidate-image-\(first.id)").accessibilityActivate())
        XCTAssertTrue(try action("candidate-image-\(second.id)").accessibilityActivate())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try action("candidate-dismiss-selected").accessibilityActivate()); try await Task.sleep(for: .milliseconds(300))
        let incoming = ScheduleCandidate(sourceAssetIdentifier: "new-photo", sourceCandidateKey: "new", title: "New", date: CalendarDate(year: 2026, month: 10, day: 11))
        context.insert(incoming); try context.save()
        let confirmation = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        let ignore = try XCTUnwrap(PresentationAutomationScope.objects(in: confirmation.view).first {
            $0.isAccessibilityElement && $0.accessibilityLabel == String(localized: "Ignore \(2) Candidates")
        })
        XCTAssertTrue(activateReviewButton(ignore, in: confirmation.view)); try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(first.reviewStatus, .dismissed); XCTAssertEqual(second.reviewStatus, .dismissed)
        XCTAssertEqual(survivor.reviewStatus, .pending); XCTAssertEqual(incoming.reviewStatus, .pending)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        XCTAssertEqual(scan.status, .completed)
        XCTAssertTrue(opened == [survivor.id])
        attach(host.view, name: "batch-success-survivors")
    }

    func testTabBadgeStaysNumericAndAnalysisCannotReplaceCandidateReview() {
        let date = CalendarDate(year: 2026, month: 10, day: 7)
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "badge", sourceCandidateKey: "one", title: "Pending", date: date)
        let reviewed = ScheduleCandidate(sourceAssetIdentifier: "badge", sourceCandidateKey: "two", title: "Reviewed", date: date, reviewStatus: .dismissed)
        for scan in [ScanStatus(state: .analyzing), ScanStatus(state: .completed)] {
            XCTAssertEqual(CandidateReviewPresentation(candidates: [candidate, reviewed], isEditing: true).badge(scanStatus: scan), "1")
            XCTAssertNil(CandidateReviewPresentation(candidates: [reviewed]).badge(scanStatus: scan))
            XCTAssertNil(CandidateReviewPresentation(candidates: []).badge(scanStatus: scan))
        }
        candidate.date = nil
        XCTAssertNotEqual(CandidateReviewPresentation(candidates: [candidate, reviewed]).state, .completed, "A hidden pending row cannot prove all review is complete")
    }

    func testBatchFailureKeepsAllDataAndSelectionForRetry() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        for failure in ["save", "state"] {
            let container = try SnapScheduleModelContainer.makeInMemory()
            let context = container.mainContext; context.autosaveEnabled = false
            let first = ScheduleCandidate(sourceAssetIdentifier: "failure-photo", sourceCandidateKey: "first", title: "First", date: CalendarDate(year: 2026, month: 10, day: 8))
            let second = ScheduleCandidate(sourceAssetIdentifier: "failure-photo", sourceCandidateKey: "second", title: "Second", date: CalendarDate(year: 2026, month: 10, day: 9))
            [first, second].forEach { context.insert($0) }; try context.save()
            let selection = CandidateSelectionState(); var shouldFail = failure == "save"
            let host = UIHostingController(rootView: NavigationStack {
                CandidateListView(selectionState: selection, onOpenCandidate: { _ in XCTFail("Selection cannot open editor") }, dismissalSave: { ctx in
                    if shouldFail { throw NSError(domain: "BatchSaveFailure", code: 1) }; try ctx.save()
                })
            }.modelContainer(container).environment(\.screenshotThumbnailFactory, { id in
                let data = self.sourceImage().pngData()!
                return ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) }
            }))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(400))
            func activate(_ id: String) async throws {
                func find() -> NSObject? { PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == id && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) } }
                if find() == nil, let scroll = self.firstScroll(host.view) {
                    for step in 0..<25 {
                        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 140), animated: false)
                        try await Task.sleep(for: .milliseconds(100))
                        if find() != nil { break }
                    }
                }
                let object = try XCTUnwrap(find(), id)
                XCTAssertTrue(self.activateReviewButton(object, in: host.view)); try await Task.sleep(for: .milliseconds(200))
            }
            func waitForDialog(title: String? = nil) async throws -> UIAlertController {
                func find(_ controller: UIViewController) -> UIAlertController? {
                    if let alert = controller as? UIAlertController { return alert }
                    if let presented = controller.presentedViewController, let alert = find(presented) { return alert }
                    return controller.children.compactMap(find).first
                }
                var presented: UIAlertController?
                for _ in 0..<40 {
                    if let dialog = find(host), !dialog.isBeingDismissed,
                       dialog.view.window != nil, title == nil || dialog.title == title {
                        presented = dialog
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                return try XCTUnwrap(presented, "Expected displayed dialog: \(title ?? "confirmation")")
            }
            func confirm() async throws {
                let dialog = try await waitForDialog()
                XCTAssertTrue(PresentationAutomationScope.objects(in: dialog.view).compactMap(\.accessibilityLabel).joined().contains("2"))
                let button = try XCTUnwrap(PresentationAutomationScope.objects(in: dialog.view).first { $0.isAccessibilityElement && $0.accessibilityLabel == String(localized: "Ignore \(2) Candidates") })
                XCTAssertTrue(self.activateReviewButton(button, in: dialog.view)); try await Task.sleep(for: .milliseconds(400))
            }
            try await activate("candidate-selection-start")
            try await activate("candidate-image-\(first.id)")
            try await activate("candidate-image-\(second.id)")
            try await activate("candidate-dismiss-selected")
            if failure == "state" { second.reviewStatus = .registered; second.registeredScheduleID = UUID(); try context.save() }
            try await confirm()
            XCTAssertEqual(first.reviewStatus, .pending, "No partial ignore on \(failure)")
            XCTAssertEqual(second.reviewStatus, failure == "state" ? .registered : .pending)
            XCTAssertEqual(selection.dismissalCandidateIDs, [first.id, second.id])
            XCTAssertTrue(selection.isDismissSelectionActive)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
            let error = try await waitForDialog(title: String(localized: "Candidate Could Not Be Ignored"))
            try await Task.sleep(for: .milliseconds(400))
            attach(window, name: "batch-\(failure)-error")
            let ok = try XCTUnwrap(PresentationAutomationScope.objects(in: error.view).first { $0.isAccessibilityElement && $0.accessibilityLabel == String(localized: "OK") })
            XCTAssertTrue(activateReviewButton(ok, in: error.view)); try await Task.sleep(for: .milliseconds(300))
            shouldFail = false
            if failure == "state" { second.reviewStatus = .pending; second.registeredScheduleID = nil; try context.save() }
            try await activate("candidate-dismiss-selected"); try await confirm()
            XCTAssertEqual(first.reviewStatus, .dismissed); XCTAssertEqual(second.reviewStatus, .dismissed)
            XCTAssertFalse(selection.isDismissSelectionActive); XCTAssertTrue(selection.dismissalCandidateIDs.isEmpty)
            attach(host.view, name: "batch-\(failure)-retry-success")
        }
    }

    func testNativeReviewTabsFitPhoneSizesAndShowActualCandidateState() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        for (state, count) in [("pending", 2), ("progress", 1), ("complete", 0)] {
            let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
            let first = ScheduleCandidate(sourceAssetIdentifier: "tab-photo", sourceCandidateKey: "first", title: "First", date: CalendarDate(year: 2026, month: 10, day: 8), reviewStatus: state == "pending" ? .pending : .dismissed)
            let second = ScheduleCandidate(sourceAssetIdentifier: "tab-photo", sourceCandidateKey: "second", title: "Second", date: CalendarDate(year: 2026, month: 10, day: 9), reviewStatus: state == "complete" ? .registered : .pending)
            [first, second].forEach { context.insert($0) }; try context.save()
            let suite = "review-tabs-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
            let scanner = ScanCoordinator(context: context, settings: AppSettings(userDefaults: defaults),
                discover: { .unavailable($0) }, loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in XCTFail("No real OCR"); return [] })
            let navigation = AppTabNavigation(); navigation.tab = .candidates
            let data = sourceImage().pngData()!
            let root = HomeView(scanCoordinator: scanner, notificationNavigation: NotificationNavigationStore(),
                notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission"); return false }),
                notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()),
                photoAuthorization: PhotoAuthorizationService(statusProvider: { .denied }, authorizationRequester: { XCTFail("No permission"); return .denied }), navigation: navigation)
                .modelContainer(container).environment(\.scenePhase, .active)
                .environment(\.screenshotThumbnailFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) } })
            let host = UIHostingController(rootView: AnyView(root))
            let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
            defer { scanner.cancel(); window.isHidden = true; previous?.makeKeyAndVisible() }
            for (sizeName, size, large) in [("small", CGSize(width: 375, height: 667), false), ("large", CGSize(width: 428, height: 926), false), ("AX5", CGSize(width: 375, height: 667), true), ("landscape", CGSize(width: 667, height: 375), false)] {
                host.rootView = AnyView(root.environment(\.dynamicTypeSize, large ? .accessibility5 : .large))
                host.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraExtraLarge : .large
                window.frame = CGRect(origin: .zero, size: size); host.view.frame = window.bounds
                try await Task.sleep(for: .milliseconds(400)); host.view.layoutIfNeeded()
                let bar = try XCTUnwrap(descendantsForResponsive(host.view).compactMap { $0 as? UITabBar }.first)
                let items = try XCTUnwrap(bar.items); XCTAssertEqual(items.count, 3)
                XCTAssertEqual(items[0].title, String(localized: "Candidate review"))
                XCTAssertEqual(items[0].badgeValue, count == 0 ? nil : "1", "The fixture's legacy records all share one photo")
                let barBounds = bar.convert(bar.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(barBounds.minX, -1); XCTAssertLessThanOrEqual(barBounds.maxX, size.width + 1)
                let reviewLabels = descendantsForResponsive(bar).compactMap({ $0 as? UILabel }).filter { $0.text == items[0].title }
                XCTAssertFalse(reviewLabels.isEmpty, "The localized review title must actually be rendered")
                for label in reviewLabels {
                    var ancestor = label.superview
                    while let current = ancestor, !(current is UIControl), current !== bar { ancestor = current.superview }
                    let button = try XCTUnwrap(ancestor as? UIControl, "Find the real system tab button, including floating/centered iOS26 layouts")
                    let rect = label.convert(label.bounds, to: button)
                    print("Native tab bounds \(state) \(sizeName): title=\(rect), button=\(button.bounds), type=\(type(of: button))")
                    XCTAssertGreaterThanOrEqual(rect.minX, -1)
                    XCTAssertLessThanOrEqual(rect.maxX, button.bounds.width + 1, "Review title must fit its actual system button")
                    XCTAssertGreaterThanOrEqual(rect.minY, -1)
                    XCTAssertLessThanOrEqual(rect.maxY, button.bounds.height + 1)
                }
                for scroll in descendantsForResponsive(host.view).compactMap({ $0 as? UIScrollView }) {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                }
                attach(host.view, name: "review-tab-\(state)-\(sizeName)")
            }
        }
    }

    func testInlineDateTimeZoneReviewRemainsRequiredWithoutDuplicateReviewSection() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        for large in [false, true] {
            let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
            let candidate = ScheduleCandidate(sourceAssetIdentifier: "inline-photo", sourceCandidateKey: "inline", evidenceText: "Meeting 2026-10-08 09:00 ~ 18:00", title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 8), time: ClockTime(hour: 9, minute: 0), timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.relativeDate, .uncertainTimeAssociation, .timeRangeNotStored, .timeZoneInferred])
            context.insert(candidate); try context.save()
            let navigation = AppTabNavigation(); navigation.tab = .candidates; navigation.candidateDetailID = candidate.id
            let image = sourceImage().pngData()!
            let host = UIHostingController(rootView: NavigationStack {
                CandidateDetailView(candidate: candidate,
                    notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission"); return false }),
                    notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()), navigation: navigation)
            }.modelContainer(container).environment(\.dynamicTypeSize, large ? .accessibility5 : .large)
                .environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: image, orientation: .up) } }))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: large ? 375 : 428, height: large ? 667 : 926)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { navigation.candidateWillLeave = nil; window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(400))
            let scroll = try XCTUnwrap(firstScroll(host.view))
            var labels: Set<String> = []
            var reasonIDs: Set<String> = []
            for step in 0..<40 {
                let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(CGFloat(step) * 140, bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let objects = PresentationAutomationScope.objects(in: host.view).filter(\.isAccessibilityElement)
                labels.formUnion(objects.compactMap(\.accessibilityLabel))
                reasonIDs.formUnion(objects.compactMap(pairingIdentifier).filter { $0.hasPrefix("candidate-review-") })
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                if objects.contains(where: { (self.pairingIdentifier($0) ?? "").hasPrefix("candidate-review-") }) {
                    attach(host.view, name: "inline-confirmations-\(large ? "AX5" : "normal")-\(step)")
                }
            }
            XCTAssertEqual(reasonIDs, ["candidate-review-relativeDate", "candidate-review-uncertainTimeAssociation", "candidate-review-timeRangeNotStored"])
            XCTAssertFalse(labels.contains(String(localized: "Review")))
            XCTAssertFalse(labels.contains(String(localized: "No analysis warnings")))
            XCTAssertFalse(labels.contains(String(localized: "Registration")))
            XCTAssertFalse(labels.contains(candidate.evidenceText!)); XCTAssertTrue(labels.contains(String(localized: "Apple Calendar")))
            for (index, id) in ["relativeDate", "uncertainTimeAssociation", "timeRangeNotStored"].enumerated() {
                let register = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
                XCTAssertTrue(register.accessibilityTraits.contains(.notEnabled), "Each unresolved reason must prevent registration")
                var toggle: NSObject?
                for step in 0..<40 {
                    scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 140), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    toggle = PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == "candidate-review-\(id)" && $0.isAccessibilityElement }
                    if toggle != nil { break }
                }
                XCTAssertTrue(try XCTUnwrap(toggle).accessibilityActivate())
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(candidate.reviewReasons.count, 4, "Confirmations remain draft edits")
                if index == 2 {
                    let ready = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
                    XCTAssertFalse(ready.accessibilityTraits.contains(.notEnabled))
                }
            }
            navigation.tab = .settings
            XCTAssertEqual(candidate.reviewStatus, .pending); XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred])
            XCTAssertEqual(candidate.time, ClockTime(hour: 9, minute: 0)); XCTAssertEqual(candidate.sourceAssetIdentifier, "inline-photo")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0, "Leaving saves without registration")
        }
    }

    func testEstimatedZoneAndTimeCanRegisterWithoutToggleOrEvidenceDisplay() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory(); let context = container.mainContext
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "zone-ui-photo", sourceCandidateKey: "zone", evidenceText: "HIDDEN RECOGNITION EVIDENCE", title: "Meeting", date: CalendarDate(year: 2026, month: 10, day: 8), time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.timeZoneInferred])
        context.insert(candidate); try context.save()
        let image = sourceImage().pngData()!
        let host = UIHostingController(rootView: NavigationStack {
            CandidateDetailView(candidate: candidate, notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission"); return false }), notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()))
        }.modelContainer(container).environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: image, orientation: .up) } }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 428, height: 926); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(firstScroll(host.view)); var labels: Set<String> = []; var identifiers: Set<String> = []; var values: Set<String> = []
        for step in 0..<16 {
            scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 120), animated: false); try await Task.sleep(for: .milliseconds(100))
            let objects = PresentationAutomationScope.objects(in: host.view).filter(\.isAccessibilityElement)
            labels.formUnion(objects.compactMap(\.accessibilityLabel)); values.formUnion(objects.compactMap(\.accessibilityValue)); identifiers.formUnion(objects.compactMap(pairingIdentifier))
            if objects.contains(where: { $0.accessibilityValue?.contains("Asia/Seoul") == true || $0.accessibilityLabel?.contains("Asia/Seoul") == true }) { attach(host.view, name: "zone-no-confirmation-time-and-zone-\(step)") }
        }
        XCTAssertFalse(labels.contains(candidate.evidenceText!)); XCTAssertFalse(labels.contains(String(localized: "Evidence")))
        XCTAssertFalse(identifiers.contains("candidate-review-timeZoneInferred"))
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Time zone (estimated)")) })
        XCTAssertTrue(labels.union(values).contains { $0.contains("Asia/Seoul") }, "The displayed picker value must be readable")
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Original screenshot")) })
        let register = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { self.pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
        XCTAssertFalse(register.accessibilityTraits.contains(.notEnabled), "Valid estimated zone needs no confirmation")
        XCTAssertTrue(register.accessibilityActivate()); try await Task.sleep(for: .milliseconds(500))
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.time, ClockTime(hour: 14, minute: 0)); XCTAssertEqual(schedule.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(candidate.reviewStatus, .registered); XCTAssertEqual(candidate.evidenceText, "HIDDEN RECOGNITION EVIDENCE")
        XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred]); attach(window, name: "zone-registered-without-confirmation")
    }

    func testUncertainCandidateTimeCanBeEnteredAndStillNeedsConfirmation() async throws {
        let automation=try PresentationAutomationScope();defer {automation.restore()}
        let container=try SnapScheduleModelContainer.makeInMemory()
        let candidate=ScheduleCandidate(sourceAssetIdentifier:"time-entry-fixture",sourceCandidateKey:"date-8",evidenceText:"Meeting 2026-10-08 2026-10-09 09:00 14:00",title:"Meeting",date:CalendarDate(year:2026,month:10,day:8),reviewReasons:CandidateReviewReason(rawValue:"uncertainTimeAssociation").map {[$0]} ?? [])
        container.mainContext.insert(candidate);try container.mainContext.save()
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first {$0.isKeyWindow}
        let host=UIHostingController(rootView:NavigationStack {
            CandidateDetailView(candidate:candidate,notificationAuthorization:NotificationAuthorizationService(statusProvider:{.denied},authorizationRequester:{_ in XCTFail("No permission request");return false}),notificationScheduler:NotificationScheduler(center:DesignNotificationCenter()))
        }.modelContainer(container))
        let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:428,height:926);window.rootViewController=host;window.makeKeyAndVisible()
        defer {window.isHidden=true;previous?.makeKeyAndVisible()}
        try await Task.sleep(for:.milliseconds(400))
        let scroll=try XCTUnwrap(firstScroll(host.view))
        var control:NSObject?
        for step in 0..<15 {
            scroll.setContentOffset(CGPoint(x:0,y:CGFloat(step)*100),animated:false)
            try await Task.sleep(for:.milliseconds(120))
            control=PresentationAutomationScope.objects(in:host.view).first(where: {pairingIdentifier($0) == "candidate-set-time"})
            if control != nil {break}
        }
        let setTime=try XCTUnwrap(control,"An unpaired date must allow explicit time entry")
        XCTAssertTrue(setTime.accessibilityActivate())
        try await Task.sleep(for:.milliseconds(300))
        let sheet=try XCTUnwrap(host.presentedViewController)
        let save=try XCTUnwrap(PresentationAutomationScope.objects(in:sheet.view).first(where: {pairingIdentifier($0) == "candidate-time-save" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
        XCTAssertTrue(save.accessibilityTraits.contains(.notEnabled),"Blank input must not invent a time")
        let field=try XCTUnwrap(descendantsForResponsive(sheet.view).compactMap {$0 as? UITextField}.first)
        field.text="25:00";field.sendActions(for:.editingChanged)
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertTrue(try XCTUnwrap(PresentationAutomationScope.objects(in:sheet.view).first(where: {pairingIdentifier($0) == "candidate-time-save" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)})).accessibilityTraits.contains(.notEnabled))
        field.text="14:00";field.sendActions(for:.editingChanged)
        try await Task.sleep(for:.milliseconds(120))
        attach(sheet.view,name:"pairing-time-entry")
        let validSave=try XCTUnwrap(PresentationAutomationScope.objects(in:sheet.view).first(where: {pairingIdentifier($0) == "candidate-time-save" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
        XCTAssertFalse(validSave.accessibilityTraits.contains(.notEnabled));XCTAssertTrue(validSave.accessibilityActivate())
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertNil(candidate.time,"The editor draft is separate from the pending model")
        let register=try XCTUnwrap(PresentationAutomationScope.objects(in:host.view).first(where: {pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
        XCTAssertTrue(register.accessibilityTraits.contains(.notEnabled),"Entering a time alone must not confirm its date pairing")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()),0)
        attach(host.view,name:"pairing-entered-still-unconfirmed")
        var confirmation:NSObject?
        for step in 0..<20 {
            scroll.setContentOffset(CGPoint(x:0,y:CGFloat(step)*100),animated:false)
            try await Task.sleep(for:.milliseconds(120))
            confirmation=PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-review-uncertainTimeAssociation" && $0.isAccessibilityElement})
            if confirmation != nil {break}
        }
        attach(host.view,name:"pairing-entered-evidence-confirmation")
        XCTAssertTrue(try XCTUnwrap(confirmation).accessibilityActivate())
        try await Task.sleep(for:.milliseconds(200))
        let ready=try XCTUnwrap(PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
        XCTAssertFalse(ready.accessibilityTraits.contains(.notEnabled))
        attach(host.view,name:"pairing-confirmed-ready")
        XCTAssertTrue(ready.accessibilityActivate())
        try await Task.sleep(for:.milliseconds(500))
        let schedule=try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.time,ClockTime(hour:14,minute:0));XCTAssertEqual(schedule.date,CalendarDate(year:2026,month:10,day:8))
        XCTAssertEqual(candidate.reviewStatus,.registered);XCTAssertEqual(candidate.registeredScheduleID,schedule.id)
        attach(host.view,name:"pairing-registered")
    }

    func testDateTimeCandidateGalleryRangeEditingAndRegistrationScreens() async throws {
        let automation=try PresentationAutomationScope();defer {automation.restore()}
        let language=Bundle.main.preferredLocalizations.first ?? "ko"
        let title=language == "ja" ? "会議":language == "en" ? "Meeting":"회의"
        let interview=language == "ja" ? "面接":language == "en" ? "Interview":"면접"
        let cases=[("normal","\(title) 2026-10-08 09:00 KST, \(interview) 2026-10-09 14:00 KST"),
                   ("ambiguous","\(title) 2026-10-08 2026-10-09 09:00 14:00"),
                   ("range","\(title) 2026-10-08 09:00 KST ~ 18:00 KST")]
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first {$0.isKeyWindow}
        for (name,text) in cases {
            let container=try SnapScheduleModelContainer.makeInMemory();let context=container.mainContext
            let queue=ScanQueue(context:context)
            try queue.prepare(for:.authorized([ScreenshotAssetMetadata(assetIdentifier:"pairing-\(name)",creationDate:nil,pixelWidth:2000,pixelHeight:700)]))
            let owner=try queue.beginExecution();let scan=try XCTUnwrap(queue.claimNext(owner:owner))
            let suite="PairingScreens.\(UUID())";let defaults=try XCTUnwrap(UserDefaults(suiteName:suite));defer {defaults.removePersistentDomain(forName:suite)}
            let settings=AppSettings(userDefaults:defaults);settings.reminderDayBefore=false;settings.reminderSameDay=false;settings.defaultExportToCalendar=false
            let fragments=[RecognizedTextFragment(text:text,boundingBox:CGRect(x:0.04,y:0.75,width:0.9,height:0.08),confidence:1)]
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:nil,analysisDate:Date(timeIntervalSince1970:1791334800),timeZone:TimeZone(identifier:"Asia/Seoul")!)
            try CandidateCreationService(context:context,scanQueue:queue).completeAnalysis(scan,owner:owner,drafts:drafts,fragments:fragments,settings:settings,analysisVersion:"vision3-parser2-filter1")
            let candidates=try context.fetch(FetchDescriptor<ScheduleCandidate>()).sorted {$0.date!.day < $1.date!.day}
            XCTAssertEqual(candidates.count,1)
            XCTAssertEqual(candidates[0].recognizedDateOptions.count, name == "range" ? 0 : 2)
            let source=UIGraphicsImageRenderer(size:CGSize(width:2000,height:1000)).image { c in
                UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:2000,height:1000))
                text.draw(in:CGRect(x:80,y:120,width:1800,height:700),withAttributes:[.font:UIFont.monospacedSystemFont(ofSize:64,weight:.semibold),.foregroundColor:UIColor.black])
            }
            let sourceData=try XCTUnwrap(source.pngData())
            let selection=CandidateSelectionState();selection.synchronize(with:candidates)
            XCTAssertEqual(selection.selectedCount,0)
            let denied=NotificationAuthorizationService(statusProvider:{.denied},authorizationRequester:{_ in XCTFail("No permission request");return false})
            let center=NotificationScheduler(center:DesignNotificationCenter())
            try await render(NavigationStack {CandidateListView(selectionState:selection,onOpenCandidate:{_ in},notificationAuthorization:denied,notificationScheduler:center)}.modelContainer(container).environment(\.screenshotThumbnailFactory,{id in ScreenshotPreviewModel(sourceScreenshotIdentifier:id) {_,_ in ScreenshotImageInput(data:sourceData,orientation:.up)}}),name:"pairing-\(name)-gallery-\(language)",scheme:.light,large:false,size:CGSize(width:428,height:926))
            let candidate=try XCTUnwrap(candidates.first)
            let host=UIHostingController(rootView:NavigationStack {CandidateDetailView(candidate:candidate,notificationAuthorization:denied,notificationScheduler:center)}.modelContainer(container).environment(\.screenshotPreviewFactory,{id in ScreenshotPreviewModel(sourceScreenshotIdentifier:id) {_,_ in ScreenshotImageInput(data:sourceData,orientation:.up)}}))
            let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:428,height:926);window.rootViewController=host;window.makeKeyAndVisible()
            defer {window.isHidden=true;previous?.makeKeyAndVisible()}
            try await Task.sleep(for:.milliseconds(400))
            let register=try XCTUnwrap(PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
            XCTAssertTrue(register.accessibilityTraits.contains(.notEnabled))
            attach(host.view,name:"pairing-\(name)-editor-top-\(language)")
            let field=try XCTUnwrap(descendantsForResponsive(host.view).compactMap {$0 as? UITextView}.first)
            field.text="Reviewed \(title)";field.delegate?.textViewDidChange?(field)
            let scroll=try XCTUnwrap(firstScroll(host.view))
            if candidate.reviewReasons.contains(.ambiguousDate) {
                var confirmation: NSObject?
                for step in 0..<18 {
                    scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 100), animated: false)
                    try await Task.sleep(for: .milliseconds(120))
                    confirmation = PresentationAutomationScope.objects(in: host.view).first {
                        pairingIdentifier($0) == "candidate-review-ambiguousDate" && $0.isAccessibilityElement
                    }
                    if confirmation != nil { break }
                }
                XCTAssertTrue(try XCTUnwrap(confirmation).accessibilityActivate())
            }
            if name == "range" {
                var timePicker:UIDatePicker?
                for step in 0..<12 {
                    scroll.setContentOffset(CGPoint(x:0,y:CGFloat(step)*100),animated:false);try await Task.sleep(for:.milliseconds(120))
                    timePicker=descendantsForResponsive(host.view).compactMap {$0 as? UIDatePicker}.first(where:{$0.datePickerMode == .time})
                    if timePicker != nil {break}
                }
                let picker=try XCTUnwrap(timePicker)
                var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone.current
                picker.date=try XCTUnwrap(calendar.date(from:DateComponents(year:2001,month:1,day:1,hour:10,minute:30)))
                picker.sendActions(for:.valueChanged)
            }
            let reason = name == "range" ? "timeRangeNotStored":"uncertainTimeAssociation"
            if name != "normal" {
                var confirmation:NSObject?
                for step in 0..<18 {
                    scroll.setContentOffset(CGPoint(x:0,y:CGFloat(step)*100),animated:false);try await Task.sleep(for:.milliseconds(120))
                    confirmation=PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-review-\(reason)" && $0.isAccessibilityElement})
                    if confirmation != nil {break}
                }
                let toggle=try XCTUnwrap(confirmation)
                let expectedMessage: String
                if name == "range" {
                    expectedMessage = language == "ja" ? "この時刻のみ保存し、終了時刻・所要時間は保存しないことを確認" : language == "en" ? "Confirm only this time is saved, without an end time or duration" : "이 시각만 저장하고 종료 시각·기간은 저장하지 않음을 확인"
                } else {
                    expectedMessage = language == "ja" ? "日付と時刻の対応、または時刻なしで保存することを確認" : language == "en" ? "Confirm the date and time pairing, or save without a time" : "날짜·시간 연결을 확인하거나, 시간 없이 저장할지 확인"
                }
                XCTAssertTrue(toggle.accessibilityLabel?.contains(expectedMessage) == true,"The user must see the explanation in the actual process language")
                attach(host.view,name:"pairing-\(name)-evidence-before-confirmation-\(language)")
                let evidenceOffset=scroll.contentOffset
                let evidenceBottom=max(-scroll.adjustedContentInset.top,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x:0,y:min(evidenceOffset.y+330,evidenceBottom)),animated:false)
                try await Task.sleep(for:.milliseconds(120))
                attach(host.view,name:"pairing-\(name)-evidence-bottom-\(language)")
                scroll.setContentOffset(evidenceOffset,animated:false)
                try await Task.sleep(for:.milliseconds(120))
                XCTAssertTrue(toggle.accessibilityActivate())
            }
            try await Task.sleep(for:.milliseconds(200))
            let ready=try XCTUnwrap(PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-register" && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)}))
            XCTAssertFalse(ready.accessibilityTraits.contains(.notEnabled))
            attach(host.view,name:"pairing-\(name)-confirmed-ready-\(language)")
            XCTAssertTrue(ready.accessibilityActivate());try await Task.sleep(for:.milliseconds(500))
            let saved=try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
            XCTAssertEqual(saved.title,"Reviewed \(title)")
            XCTAssertEqual(saved.date,CalendarDate(year:2026,month:10,day:8))
            XCTAssertEqual(saved.time,name == "ambiguous" ? nil:ClockTime(hour:name == "range" ? 10:9,minute:name == "range" ? 30:0))
            XCTAssertEqual(candidate.reviewStatus,.registered);XCTAssertEqual(candidate.evidenceText,drafts.first?.evidenceText)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()),1)
            XCTAssertEqual(CandidateListPresentation.pending(candidates).count,0)
            attach(host.view,name:"pairing-\(name)-registered-\(language)")
            window.isHidden=true
        }
    }

    func testTimeReviewWarningsRemainReachableAtLargestTextOnSmallPhone() async throws {
        let automation=try PresentationAutomationScope();defer {automation.restore()}
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first {$0.isKeyWindow}
        let language=Bundle.main.preferredLocalizations.first ?? "ko"
        for reason in [CandidateReviewReason.uncertainTimeAssociation,.timeRangeNotStored] {
            let container=try SnapScheduleModelContainer.makeInMemory()
            let candidate=ScheduleCandidate(sourceAssetIdentifier:"large-time-review",sourceCandidateKey:reason.rawValue,evidenceText:reason == .timeRangeNotStored ? "Meeting 2026-10-08 09:00~18:00":"Meeting 2026-10-08 2026-10-09 09:00 14:00",title:"Meeting",date:CalendarDate(year:2026,month:10,day:8),time:reason == .timeRangeNotStored ? ClockTime(hour:9,minute:0):nil,timeZoneIdentifier:reason == .timeRangeNotStored ? "Asia/Seoul":nil,reviewReasons:[reason])
            container.mainContext.insert(candidate);try container.mainContext.save()
            let host=UIHostingController(rootView:NavigationStack {CandidateDetailView(candidate:candidate)}.modelContainer(container).environment(\.dynamicTypeSize,.accessibility5).environment(\.snapCompactTypography,true))
            host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            let window=UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:375,height:667);window.rootViewController=host;window.makeKeyAndVisible()
            defer {window.isHidden=true;previous?.makeKeyAndVisible()}
            try await Task.sleep(for:.milliseconds(400))
            let scroll=try XCTUnwrap(firstScroll(host.view))
            var reachable=false
            for step in 0..<40 {
                let top = -scroll.adjustedContentInset.top
                let maxOffset=max(top,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x:0,y:min(top+CGFloat(step)*180,maxOffset)),animated:false)
                try await Task.sleep(for:.milliseconds(100));host.view.layoutIfNeeded()
                XCTAssertLessThanOrEqual(scroll.contentSize.width,scroll.bounds.width+1,"No horizontal scrolling")
                if let toggle=PresentationAutomationScope.objects(in:host.view).first(where:{pairingIdentifier($0) == "candidate-review-\(reason.rawValue)" && $0.isAccessibilityElement}) {
                    let frame=host.view.convert(toggle.accessibilityFrame,from:nil)
                    if frame.intersects(CGRect(x:0,y:80,width:375,height:500)) {
                        XCTAssertGreaterThanOrEqual(frame.minX,-1);XCTAssertLessThanOrEqual(frame.maxX,376)
                        XCTAssertGreaterThanOrEqual(frame.height,44)
                        attach(host.view,name:"pairing-\(reason.rawValue)-AX5-\(language)-\(step)")
                        reachable=true;break
                    }
                }
            }
            XCTAssertTrue(reachable,"Large translated warning and confirmation must be reachable")
            XCTAssertFalse(candidate.isRegistrationEligible);XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()),0)
            window.isHidden=true
        }
    }

    func testEightTitlePresetsFitAndPreserveFillingSelectionAndDirectInput() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let expected: [String]
        switch language {
        case "en": expected = ["Work", "Application", "Deadline", "Gift voucher", "Ticket booking", "Event", "Reservation", "Appointment"]
        case "ja": expected = ["業務", "申込み", "締切", "ギフト券", "チケット予約", "イベント", "予約", "約束"]
        default: expected = ["업무", "신청", "마감", "기프티콘", "티켓팅", "이벤트", "예약", "약속"]
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        for (name, size, large) in [("small", CGSize(width:375,height:667), false),
                                    ("large", CGSize(width:428,height:926), false),
                                    ("small-AX5", CGSize(width:375,height:667), true)] {
            let container = try SnapScheduleModelContainer.makeInMemory()
            let candidate = ScheduleCandidate(sourceAssetIdentifier:"title-only-fixture", sourceCandidateKey:name,
                title:"지원서", date:CalendarDate(year:2030,month:11,day:2), reviewReasons:[.relativeDate])
            container.mainContext.insert(candidate); try container.mainContext.save()
            let host = UIHostingController(rootView: NavigationStack {
                CandidateDetailView(candidate:candidate,
                    notificationAuthorization:NotificationAuthorizationService(statusProvider:{.denied},authorizationRequester:{_ in XCTFail("No permission request");return false}),
                    notificationScheduler:NotificationScheduler(center:DesignNotificationCenter()))
            }.modelContainer(container).environment(\.dynamicTypeSize,large ? .accessibility5:.large)
                .environment(\.snapCompactTypography,size.width <= 375))
            host.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraExtraLarge:.large
            let window = UIWindow(windowScene:scene); window.frame=CGRect(origin:.zero,size:size)
            window.rootViewController=host; window.makeKeyAndVisible()
            defer { window.isHidden=true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for:.milliseconds(450)); host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(firstScroll(host.view))
            var frames:[String:CGRect]=[:]
            func controls() -> [NSObject] {
                PresentationAutomationScope.objects(in:host.view).filter { $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) }
            }
            func button(_ title:String) -> NSObject? {
                controls().first { $0.accessibilityLabel == title || $0.accessibilityLabel?.hasPrefix(title+",") == true }
            }
            let firstY = -scroll.adjustedContentInset.top
            func scrollToTitleInput() async throws -> UIView {
                let maximum=max(firstY,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                for step in 0..<30 {
                    scroll.setContentOffset(CGPoint(x:0,y:min(firstY+CGFloat(step)*140,maximum)),animated:false)
                    try await Task.sleep(for:.milliseconds(120));host.view.layoutIfNeeded()
                    if let field=descendantsForResponsive(host.view).first(where:{ $0 is UITextField || $0 is UITextView }) { return field }
                }
                throw NSError(domain:"TitleInputNotReachable",code:1)
            }
            var offset=firstY
            for step in 0..<24 {
                scroll.setContentOffset(CGPoint(x:0,y:offset),animated:false)
                try await Task.sleep(for:.milliseconds(140));host.view.layoutIfNeeded()
                let visible = controls().filter { expected.contains($0.accessibilityLabel ?? "") }
                for control in visible {
                    let screenFrame=control.accessibilityFrame
                    let local=host.view.convert(screenFrame,from:nil)
                    guard local.intersects(CGRect(x:0,y:70,width:size.width,height:size.height-140)) else {continue}
                    XCTAssertGreaterThanOrEqual(local.minX,-1,name)
                    XCTAssertLessThanOrEqual(local.maxX,size.width+1,name)
                    XCTAssertGreaterThanOrEqual(local.height,44,name)
                    frames[control.accessibilityLabel!] = CGRect(x:local.minX,y:local.minY+offset,width:local.width,height:local.height)
                }
                if !visible.isEmpty {attach(host.view,name:"title8-\(language)-\(name)-\(step)")}
                if frames.count == 8 {break}
                let maximum=max(firstY,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                if offset >= maximum {break};offset=min(offset+180,maximum)
            }
            XCTAssertEqual(Set(frames.keys),Set(expected),"All eight reachable: \(language) \(name)")
            for i in 0..<expected.count {
                for j in (i+1)..<expected.count {
                    if let a=frames[expected[i]],let b=frames[expected[j]] {
                        XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).isEmpty,"Overlap \(expected[i]) / \(expected[j])")
                    }
                }
            }
            func clustered(_ values: [CGFloat]) -> [CGFloat] {
                values.sorted().reduce(into: []) { groups, value in
                    if groups.last.map({ abs($0-value) > 2 }) ?? true { groups.append(value) }
                }
            }
            let columns=clustered(frames.values.map(\.midX))
            let rows=clustered(frames.values.map(\.midY))
            XCTAssertEqual(columns.count,large ? 1:4,"Title presets column count: \(name)")
            XCTAssertEqual(rows.count,large ? 8:2,"Title presets row count: \(name)")
            if !large, let firstRow=rows.first, let secondRow=rows.last, rows.count == 2 {
                for (index,title) in expected.enumerated() {
                    if let frame=frames[title] {
                        XCTAssertEqual(frame.midY,index < 4 ? firstRow:secondRow,accuracy:2,"Order: \(title)")
                        if columns.count == 4 {
                            XCTAssertEqual(frame.midX,columns[index % 4],accuracy:2,"Column order: \(title)")
                        }
                    }
                }
            }
            XCTAssertEqual(candidate.title,"지원서","Opening the editor must not migrate a stored title")
            for title in expected {
                guard let frame=frames[title] else {continue}
                let maximum=max(firstY,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x:0,y:min(max(firstY,frame.minY-130),maximum)),animated:false)
                try await Task.sleep(for:.milliseconds(160));host.view.layoutIfNeeded()
                let control=try XCTUnwrap(button(title),title)
                XCTAssertTrue(control.accessibilityActivate(),"Fill \(title)")
                try await Task.sleep(for:.milliseconds(120))
                // Revisit the input after each real activation; Lazy Form can release it offscreen.
                let field=try await scrollToTitleInput()
                XCTAssertEqual((field as? UITextField)?.text ?? (field as? UITextView)?.text,title)
                scroll.setContentOffset(CGPoint(x:0,y:min(max(firstY,frame.minY-130),maximum)),animated:false)
                try await Task.sleep(for:.milliseconds(160));host.view.layoutIfNeeded()
                let selected=try XCTUnwrap(button(title))
                XCTAssertTrue(selected.accessibilityTraits.contains(.selected) || selected.accessibilityLabel?.contains("checkmark") == true,
                    "Selected title should expose its check: \(selected.accessibilityLabel ?? "")")
            }
            let field=try await scrollToTitleInput()
            if let input=field as? UITextField {input.text="My custom title";input.sendActions(for:.editingChanged)}
            if let input=field as? UITextView {input.text="My custom title";input.delegate?.textViewDidChange?(input)}
            try await Task.sleep(for:.milliseconds(120))
            XCTAssertEqual((field as? UITextField)?.text ?? (field as? UITextView)?.text,"My custom title")
            XCTAssertEqual(candidate.title,"지원서","Preset activation only changes the editor draft")
            XCTAssertEqual(candidate.reviewReasons,[.relativeDate]);XCTAssertEqual(candidate.reviewStatus,.pending)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()),0)
            for scroll in descendantsForResponsive(host.view).compactMap({$0 as? UIScrollView}) {
                XCTAssertLessThanOrEqual(scroll.contentSize.width,scroll.bounds.width+1,name)
            }
            attach(host.view,name:"title8-\(language)-\(name)-direct-input")
            window.isHidden=true
        }
    }

    func testResponsivePhoneViewportsKeepContentAndLargeTextReadable() async throws {
        let automation=try PresentationAutomationScope();defer { automation.restore() }
        let container=try SnapScheduleModelContainer.makeInMemory()
        let day=CalendarDate.gregorianDate(from:.now)
        let candidates=(0..<3).map { i in ScheduleCandidate(sourceAssetIdentifier:i == 1 ? "second":"first",sourceCandidateKey:"responsive-\(i)",title:"테스트 일정 \(i+1)",date:day,reviewReasons:[.relativeDate]) }
        candidates.forEach {container.mainContext.insert($0)}
        try container.mainContext.save()
        let suite="responsive-\(UUID())";let defaults=try XCTUnwrap(UserDefaults(suiteName:suite));defer { defaults.removePersistentDomain(forName:suite) }
        let settings=AppSettings(userDefaults:defaults)
        let scanner=ScanCoordinator(context:container.mainContext,settings:settings,discover:{.unavailable($0)},loadImage:{_,_ in throw ScreenshotImageLoadError.inaccessible},recognizeText:{_ in []})
        let navigation=AppTabNavigation()
        let image=try XCTUnwrap(sourceImage().pngData())
        let root=HomeView(scanCoordinator:scanner,notificationNavigation:NotificationNavigationStore(),notificationAuthorization:NotificationAuthorizationService(statusProvider:{.denied},authorizationRequester:{_ in XCTFail("No permission request");return false}),notificationScheduler:NotificationScheduler(center:DesignNotificationCenter()),photoAuthorization:PhotoAuthorizationService(statusProvider:{.denied},authorizationRequester:{XCTFail("No permission request");return .denied}),navigation:navigation)
            .modelContainer(container).environment(\.scenePhase,.active)
            .environment(\.screenshotPreviewFactory,{id in ScreenshotPreviewModel(sourceScreenshotIdentifier:id){_,_ in ScreenshotImageInput(data:image,orientation:.up)}})
            .environment(\.screenshotThumbnailFactory,{id in ScreenshotPreviewModel(sourceScreenshotIdentifier:id){_,_ in ScreenshotImageInput(data:image,orientation:.up)}})
        let host=UIHostingController(rootView:AnyView(root))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.windows.first {$0.isKeyWindow}
        let window=UIWindow(windowScene:scene);window.rootViewController=host;window.makeKeyAndVisible()
        defer {scanner.cancel();window.isHidden=true;previous?.makeKeyAndVisible()}
        var headerHeights:[String:CGFloat]=[:],slotHeights:[String:CGFloat]=[:]
        for (name,size,large) in [("small",CGSize(width:375,height:667),false),("large",CGSize(width:428,height:926),false),("small-large-text",CGSize(width:375,height:667),true)] {
            host.rootView=AnyView(root.environment(\.dynamicTypeSize,large ? .accessibility3:.large))
            host.traitOverrides.preferredContentSizeCategory=large ? .accessibilityExtraExtraExtraLarge:.large
            window.frame=CGRect(origin:.zero,size:size);host.view.frame=window.bounds
            navigation.tab = .home
            try await Task.sleep(for:.milliseconds(700));host.view.layoutIfNeeded()
            let objects=PresentationAutomationScope.objects(in:host.view)
            let header=try XCTUnwrap(objects.first {$0.isAccessibilityElement && $0.accessibilityLabel == String(localized:"SnapSchedule calendar")})
            headerHeights[name]=header.accessibilityFrame.height
            let slot=try XCTUnwrap(objects.first {o in
                let selector=NSSelectorFromString("accessibilityIdentifier")
                return o.responds(to:selector) && (o.perform(selector)?.takeUnretainedValue() as? String) == "home-ad-placement"
            })
            slotHeights[name]=slot.accessibilityFrame.height
            XCTAssertLessThanOrEqual(slot.accessibilityFrame.height,size.height*0.18)
            let calendar=try XCTUnwrap(descendantsForResponsive(host.view).compactMap {$0 as? UICalendarView}.first)
            let calendarFrame=calendar.convert(calendar.bounds,to:host.view)
            print("Responsive calendar \(name) \(calendarFrame), viewport \(size)")
            XCTAssertGreaterThanOrEqual(calendarFrame.minX,-1,"Calendar must fit the phone width")
            XCTAssertLessThanOrEqual(calendarFrame.maxX,size.width+1,"Calendar must fit the phone width")
            attach(host.view,name:"responsive-\(name)-home")
            navigation.tab = .candidates
            try await Task.sleep(for:.milliseconds(500));host.view.layoutIfNeeded()
            attach(host.view,name:"responsive-\(name)-gallery")
            navigation.candidateDetailID=candidates[0].id
            try await Task.sleep(for:.milliseconds(500));host.view.layoutIfNeeded()
            attach(host.view,name:"responsive-\(name)-editor")
            navigation.candidateDetailID=nil;navigation.tab = .settings
            try await Task.sleep(for:.milliseconds(500));host.view.layoutIfNeeded()
            attach(host.view,name:"responsive-\(name)-settings")
            for scroll in descendantsForResponsive(host.view).compactMap({$0 as? UIScrollView}) {
                XCTAssertLessThanOrEqual(scroll.contentSize.width,scroll.bounds.width+1,"Horizontal overflow in \(name)")
            }
        }
        XCTAssertLessThan(try XCTUnwrap(slotHeights["small"]),try XCTUnwrap(slotHeights["large"]))
        XCTAssertLessThan(try XCTUnwrap(headerHeights["small"]),try XCTUnwrap(headerHeights["large"]))
        XCTAssertGreaterThan(try XCTUnwrap(headerHeights["small-large-text"]),try XCTUnwrap(headerHeights["small"]))
        XCTAssertEqual(candidates.filter {$0.reviewStatus == .pending}.count,3)
        XCTAssertEqual(Set(candidates.map(\.sourceAssetIdentifier)).count,2)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()),0)
    }

    private func descendantsForResponsive(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(descendantsForResponsive) }

    func testFailedAutosaveKeepsEditorRouteAndAllowsRetryWithoutRegistration() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "DC2BEFD2-98F0-477B-AB32-294F8E659FCA",
              case .disabled = AdsConfiguration.current.state else { throw XCTSkip("Isolated disabled build required") }
        let container = try SnapScheduleModelContainer.makeInMemory()
        container.mainContext.autosaveEnabled = false
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "save-failure", sourceCandidateKey: "one",
            title: "Before", date: CalendarDate(year: 2030, month: 11, day: 2))
        container.mainContext.insert(candidate); try container.mainContext.save()
        let navigation = AppTabNavigation(); navigation.tab = .candidates; navigation.candidateDetailID = candidate.id
        var fails = true
        let data = try XCTUnwrap(sourceImage().pngData())
        let host = UIHostingController(rootView: NavigationStack {
            CandidateDetailView(candidate: candidate, navigation: navigation, draftSave: { context in
                if fails { throw NSError(domain: "AutosaveFailure", code: 1) }
                try context.save()
            })
        }.modelContainer(container).environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: data, orientation: .up) } }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { navigation.candidateWillLeave = nil; window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let field = try XCTUnwrap(views(host.view).compactMap { $0 as? UITextView }.first)
        field.text = "Keep this edit"; field.delegate?.textViewDidChange?(field)
        navigation.tab = .settings
        navigation.candidateDetailID = nil
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(navigation.tab, .candidates)
        XCTAssertEqual(navigation.candidateDetailID, candidate.id)
        XCTAssertEqual(candidate.title, "Before")
        XCTAssertEqual(field.text, "Keep this edit")
        attach(host.view, name: "autosave-failure-editor-kept")
        fails = false
        navigation.tab = .settings
        navigation.candidateDetailID = nil
        XCTAssertEqual(navigation.tab, .settings)
        XCTAssertNil(navigation.candidateDetailID)
        XCTAssertEqual(candidate.title, "Keep this edit")
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
        #endif
    }
    // Leaving must commit an unregistered edit, including a cleared title, without creating a Schedule.
    func testLeavingEditorAutosavesPendingChangesAndReopensAfterBack() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "DC2BEFD2-98F0-477B-AB32-294F8E659FCA",
              case .disabled = AdsConfiguration.current.state else { throw XCTSkip("Isolated disabled build required") }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "autosave-fixture", sourceCandidateKey: "one",
            title: "Before editing", date: CalendarDate(year: 2030, month: 11, day: 2), reviewReasons: [.relativeDate])
        container.mainContext.insert(candidate); try container.mainContext.save()
        let suite = "task421-autosave-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        let scan = ScanCoordinator(context: container.mainContext, settings: settings,
            discover: { .unavailable($0) }, loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
        let navigation = AppTabNavigation(); navigation.tab = .candidates; navigation.candidateDetailID = candidate.id
        let imageData = try XCTUnwrap(sourceImage().pngData())
        let notificationNavigation = NotificationNavigationStore()
        let view = HomeView(scanCoordinator: scan, notificationNavigation: notificationNavigation,
            notificationAuthorization: NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission request"); return false }),
            notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()),
            photoAuthorization: PhotoAuthorizationService(statusProvider: { .denied }, authorizationRequester: { XCTFail("No permission request"); return .denied }),
            navigation: navigation).modelContainer(container).environment(\.scenePhase, .active)
            .environment(\.screenshotPreviewFactory, { id in ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in ScreenshotImageInput(data: imageData, orientation: .up) } })
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { scan.cancel(); window.isHidden = true; previous?.makeKeyAndVisible() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(650)); host.view.layoutIfNeeded() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        func edit(_ title: String) throws {
            let field = try XCTUnwrap(views(host.view).compactMap { $0 as? UITextView }.first)
            field.text = title; field.delegate?.textViewDidChange?(field)
        }
        try await settle()
        try edit("Saved without registration")
        navigation.tab = .settings
        try await settle()
        XCTAssertEqual(candidate.title, "Saved without registration")
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(candidate.reviewReasons, [.relativeDate])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
        navigation.tab = .candidates
        try await settle()
        navigation.candidateDetailID = nil
        try await settle()
        navigation.candidateDetailID = candidate.id
        try await settle()
        XCTAssertEqual(try XCTUnwrap(views(host.view).compactMap { $0 as? UITextView }.first).text, "Saved without registration")
        try edit("")
        navigation.candidateDetailID = nil
        try await settle()
        XCTAssertEqual(candidate.title, "")
        XCTAssertFalse(candidate.isRegistrationEligible)
        XCTAssertEqual(candidate.date, CalendarDate(year: 2030, month: 11, day: 2))
        XCTAssertEqual(CandidateListPresentation.pending([candidate]).map(\.id), [candidate.id])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
        let linkedSchedule = Schedule(sourceCandidateID: UUID(), title: "Existing linked schedule",
            date: CalendarDate(year: 2030, month: 11, day: 3), sourceAssetIdentifier: "linked-fixture")
        container.mainContext.insert(linkedSchedule); try container.mainContext.save()
        navigation.candidateDetailID = candidate.id
        try await settle()
        navigation.candidateWillLeave = { false }
        notificationNavigation.open(scheduleID: linkedSchedule.id)
        try await settle()
        XCTAssertEqual(navigation.tab, .candidates)
        XCTAssertEqual(notificationNavigation.destination?.scheduleID, linkedSchedule.id, "Blocked exits must keep the pending link")
        XCTAssertNil(navigation.scheduleDetailID, "A blocked exit must not route into a hidden tab")
        navigation.candidateWillLeave = { true }
        navigation.tab = .home
        try await settle()
        XCTAssertNil(notificationNavigation.destination)
        XCTAssertEqual(navigation.scheduleDetailID, linkedSchedule.id)
        #endif
    }
    func testChangedTabScreensRenderInProcessLanguage() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "DC2BEFD2-98F0-477B-AB32-294F8E659FCA",
              case .disabled = AdsConfiguration.current.state else { throw XCTSkip("Isolated disabled build required") }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "tabs-render", sourceCandidateKey: "one", title: "Review",
            date: CalendarDate.gregorianDate(from: .now))
        container.mainContext.insert(candidate); try container.mainContext.save()
        let suite = "task421-tab-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        let photo = PhotoAuthorizationService(statusProvider: { .denied }, authorizationRequester: { XCTFail("No permission request"); return .denied })
        let notifications = NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No permission request"); return false })
        let language = Bundle.main.preferredLocalizations.first ?? "unknown"
        for (scheme, large) in [(ColorScheme.light, false), (.dark, true)] {
            for tab in [AppTab.candidates, .home, .settings] {
                let navigation = AppTabNavigation(); navigation.tab = tab
                let scan = ScanCoordinator(context: container.mainContext, settings: settings,
                    discover: { .unavailable($0) }, loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
                defer { scan.cancel() }
                try await render(HomeView(scanCoordinator: scan, notificationNavigation: NotificationNavigationStore(),
                    notificationAuthorization: notifications, notificationScheduler: NotificationScheduler(center: DesignNotificationCenter()),
                    photoAuthorization: photo, navigation: navigation)
                    .modelContainer(container).environment(\.scenePhase, .active)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large),
                    name: "\(language)-tabs-\(tab)-\(scheme)", scheme: scheme, large: large)
            }
            for state in [CandidateReviewStatus.pending, .registered] {
                candidate.reviewStatus = state
                try await render(VStack(alignment: .leading, spacing: 12) {
                    CandidateReviewStatusView(presentation: CandidateReviewPresentation(candidates: [candidate], isEditing: state == .pending))
                    HomeScanStatusView(status: ScanStatus(state: state == .pending ? .analyzing : .completed,
                        photoAccess: .authorized, targetImageCount: 1, completedImageCount: state == .pending ? 0 : 1))
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large),
                    name: "\(language)-tabs-status-\(state)-\(scheme)", scheme: scheme, large: large, size: CGSize(width: 375, height: 240))
            }
            candidate.reviewStatus = .pending
        }
        #endif
    }
    func testFixedHomeSlotAndTabsPreserveDraftSelectionAndActivation() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Dedicated design Simulator only")
        #else
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == "DC2BEFD2-98F0-477B-AB32-294F8E659FCA",
              case .disabled = AdsConfiguration.current.state else {
            throw XCTSkip("Isolated disabled build required; no user data or live ad requests")
        }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "tabs-synthetic", sourceCandidateKey: "one",
            title: "Draft before switching", date: CalendarDate.gregorianDate(from: .now))
        container.mainContext.insert(candidate)
        let schedule = Schedule(sourceCandidateID: UUID(), title: "Link destination", date: CalendarDate.gregorianDate(from: .now), sourceAssetIdentifier: "tabs-synthetic")
        container.mainContext.insert(schedule)
        try container.mainContext.save()
        let suite = "task421-tabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        var discoveries = 0
        let scan = ScanCoordinator(context: container.mainContext, settings: settings,
            discover: { _ in discoveries += 1; return .authorized([]) },
            loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
        let photo = PhotoAuthorizationService(statusProvider: { .authorized }, authorizationRequester: { XCTFail("No permission request"); return .authorized })
        var notificationRefreshes = 0
        let notifications = NotificationAuthorizationService(statusProvider: { notificationRefreshes += 1; return .denied },
            authorizationRequester: { _ in XCTFail("No permission request"); return false })
        let scheduler = NotificationScheduler(center: DesignNotificationCenter())
        // Synthetic SDK boundary only; the product build itself has no ad IDs.
        let configuration = AdsConfiguration.resolve(environment: .debug,
            appID: "ca-app-pub-3940256099942544~1458002511", bannerID: "ca-app-pub-3940256099942544/2435281174")
        var allowed = false
        var loads = 0
        let manager = AdsConsentManager(configuration: configuration, sdk: .init(
            snapshot: { .init(canRequestAds: allowed, formRequired: false, privacyOptionsRequired: false) },
            update: { $0(nil) }, loadForm: { _ in XCTFail("No external form") }, privacyOptions: { _ in }, start: { $0() }))
        let controller = AdaptiveBannerController(manager: manager, configuration: configuration, load: { _, _ in loads += 1 })
        let navigation = AppTabNavigation()
        let selection = CandidateSelectionState()
        let notificationNavigation = NotificationNavigationStore()
        let view = HomeView(scanCoordinator: scan, notificationNavigation: notificationNavigation,
            notificationAuthorization: notifications, notificationScheduler: scheduler, photoAuthorization: photo,
            adsConsent: manager, bannerController: controller, navigation: navigation, candidateSelectionState: selection)
            .modelContainer(container).environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { controller.stop(); scan.cancel(); window.isHidden = true; previous?.makeKeyAndVisible() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(500)); host.view.layoutIfNeeded() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func calendarY() throws -> CGFloat {
            let calendar = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICalendarView }.first)
            return calendar.convert(calendar.bounds, to: host.view).minY
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "task421-tabs-" + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        try await settle()
        let initialY = try calendarY()
        XCTAssertEqual(loads, 0, "Space reservation cannot create an unauthorized request")
        capture("before-consent")
        allowed = true; manager.activate()
        try await settle()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(try calendarY(), initialY, accuracy: 1)
        capture("loading")
        let banner = try XCTUnwrap(controller.banner)
        let label = UILabel(); label.text = "SYNTHETIC AD LAYOUT — NO NETWORK"; label.textAlignment = .center
        label.font = .systemFont(ofSize: 10); label.backgroundColor = .systemYellow
        label.frame = CGRect(x: 0, y: 0, width: banner.adSize.size.width, height: 50); banner.addSubview(label)
        controller.adView(banner, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: banner.adSize.size.width, height: 50)))
        controller.bannerViewDidReceiveAd(banner)
        try await settle()
        XCTAssertEqual(try calendarY(), initialY, accuracy: 1)
        capture("received")
        let adY = banner.convert(banner.bounds, to: host.view).minY
        let list = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 40), animated: false)
        host.view.layoutIfNeeded()
        XCTAssertEqual(banner.convert(banner.bounds, to: host.view).minY, adY, accuracy: 1, "Ad stays outside the scrolled body")
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        controller.bannerView(banner, didFailToReceiveAdWithError: NSError(domain: "synthetic-no-fill", code: 1))
        try await settle()
        XCTAssertEqual(try calendarY(), initialY, accuracy: 1)
        XCTAssertEqual(loads, 1)
        capture("failure")
        for size in [CGSize(width: 667, height: 375), UIScreen.main.bounds.size] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            try await settle()
            let orientationY = try calendarY()
            let resized = try XCTUnwrap(controller.banner)
            controller.adView(resized, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: resized.adSize.size.width, height: 50)))
            controller.bannerViewDidReceiveAd(resized)
            try await settle()
            XCTAssertEqual(try calendarY(), orientationY, accuracy: 1)
            let frame = resized.convert(resized.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertLessThanOrEqual(frame.maxY, orientationY)
            capture(size.width > size.height ? "landscape-loaded" : "portrait-return")
        }
        let initialDiscoveries = discoveries, initialNotificationRefreshes = notificationRefreshes
        navigation.tab = .candidates
        try await settle()
        selection.toggle(candidate.id)
        let selectedIDs = selection.selectedCandidateIDs
        navigation.candidateDetailID = candidate.id
        try await settle()
        let editor = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first)
        editor.text = "Unsaved tab draft"
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        try await settle()
        XCTAssertTrue(editor.isFirstResponder)
        navigation.tab = .settings
        try await settle()
        XCTAssertNil(controller.banner)
        capture("settings")
        let loadsBeforeHomeReturn = loads
        navigation.tab = .home
        try await settle()
        XCTAssertEqual(loads, loadsBeforeHomeReturn + 1, "Keyboard dismissal must not cause extra Home requests")
        XCTAssertEqual(try calendarY(), initialY, accuracy: 1)
        navigation.tab = .candidates
        try await settle()
        let returnedEditor = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(returnedEditor.text, "Unsaved tab draft")
        XCTAssertEqual(candidate.title, "Unsaved tab draft", "Leaving saves edits without registering the schedule")
        XCTAssertEqual(selection.selectedCandidateIDs, selectedIDs)
        XCTAssertEqual(discoveries, initialDiscoveries, "Tab changes cannot reactivate analysis")
        XCTAssertEqual(notificationRefreshes, initialNotificationRefreshes, "Tab changes cannot repeat reminder synchronization")
        capture("candidate-draft-return")
        notificationNavigation.open(scheduleID: schedule.id)
        try await settle()
        XCTAssertEqual(navigation.tab, .home)
        XCTAssertEqual(navigation.scheduleDetailID, schedule.id)
        XCTAssertNil(controller.banner, "Linked schedule detail cannot display Home ads")
        capture("notification-detail")
        #endif
    }
    func testCandidateReviewCompletionRequiresReviewedCandidates() {
        let date = CalendarDate(year: 2026, month: 10, day: 7)
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "status", sourceCandidateKey: "one", title: "Review", date: date)
        let analyzed = ScanStatus(state: .completed, photoAccess: .authorized, targetImageCount: 1, completedImageCount: 1)
        XCTAssertEqual(CandidateReviewPresentation(candidates: []).state, .empty)
        XCTAssertNil(CandidateReviewPresentation(candidates: []).badge(scanStatus: analyzed))
        XCTAssertEqual(CandidateReviewPresentation(candidates: [candidate]).state, .available)
        XCTAssertEqual(CandidateReviewPresentation(candidates: [candidate], isEditing: true).state, .inProgress)
        let reviewed = ScheduleCandidate(sourceAssetIdentifier: "status", sourceCandidateKey: "two", title: "Done", date: date, reviewStatus: .dismissed)
        XCTAssertEqual(CandidateReviewPresentation(candidates: [candidate, reviewed]).state, .inProgress)
        candidate.reviewStatus = .registered
        XCTAssertEqual(CandidateReviewPresentation(candidates: [candidate, reviewed]).state, .completed)
        reviewed.date = nil
        XCTAssertEqual(CandidateReviewPresentation(candidates: [reviewed]).state, .empty)
        XCTAssertNil(CandidateReviewPresentation(candidates: [candidate]).badge(scanStatus: ScanStatus(state: .analyzing)), "Analysis cannot replace a completed review with an analyzing badge")
    }
    func testCompactAnalysisStatusDistinguishesCurrentBatchFromPendingCandidates() {
        let analyzed = ScanStatus(state: .completed, photoAccess: .authorized,
            targetImageCount: 1, completedImageCount: 1, pendingCandidateCount: 0)
        let noNewImages = ScanStatus(state: .completed, photoAccess: .authorized,
            targetImageCount: 0, pendingCandidateCount: 3)
        XCTAssertEqual(HomeScanStatusView(status: analyzed).statusTitle, String(localized: "Analysis complete"))
        XCTAssertFalse(HomeScanStatusView(status: noNewImages).isVisible)
        XCTAssertTrue(HomeScanStatusView(status: analyzed).isVisible)
        for state in [ScanRunState.discovering, .analyzing] {
            XCTAssertEqual(HomeScanStatusView(status: ScanStatus(state: state)).statusTitle, String(localized: "Analyzing screenshots"))
        }
        let failed = ScanStatus(state: .completed, photoAccess: .authorized,
            targetImageCount: 1, failedImageCount: 1)
        XCTAssertEqual(HomeScanStatusView(status: failed).statusTitle, String(localized: "Analysis completed with failures"))
        XCTAssertTrue(HomeScanStatusView(status: ScanStatus(state: .completed, targetImageCount: 0,
            lastErrorMessage: "Failed")).isVisible)
    }

    func testCompactAnalysisStatesRenderWithoutControls() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Design Simulator only")
        #else
        let designDevices = ["DC2BEFD2-98F0-477B-AB32-294F8E659FCA", "9713C13F-7AB6-47F8-883A-FBF7125B1B3F"]
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              designDevices.contains(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? ""),
              case .disabled = AdsConfiguration.current.state else {
            throw XCTSkip("Explicit unconfigured Task42-1 design runner required")
        }
        let language = Bundle.main.preferredLocalizations.first ?? "unknown"
        let states: [(String, ScanStatus)] = [
            ("analyzing", ScanStatus(state: .analyzing, photoAccess: .authorized)),
            ("complete", ScanStatus(state: .completed, photoAccess: .authorized, targetImageCount: 2, completedImageCount: 2)),
            ("empty", ScanStatus(state: .completed, photoAccess: .authorized)),
            ("failed", ScanStatus(state: .completedWithFailures, photoAccess: .authorized, targetImageCount: 2, completedImageCount: 1, failedImageCount: 1))
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, status) in states {
                try await render(HomeScanStatusView(status: status)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .environment(\.colorScheme, scheme)
                    .background(Color(uiColor: .systemBackground)),
                    name: "\(language)-\(scheme)-compact-status-\(name)", scheme: scheme, large: scheme == .dark,
                    size: CGSize(width: 329, height: 180))
            }
        }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "status-cleanup", sourceCandidateKey: "one",
            title: "Review", date: CalendarDate.gregorianDate(from: .now))
        container.mainContext.insert(candidate)
        try container.mainContext.save()
        for scheme in [ColorScheme.light, .dark] {
            try await render(NavigationStack {
                CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in },
                    scanStatus: ScanStatus(state: .completed, photoAccess: .authorized, targetImageCount: 0),
                    reviewPresentation: CandidateReviewPresentation(candidates: [candidate], isEditing: true))
            }.modelContainer(container), name: "\(language)-\(scheme)-gallery-no-new-analysis",
                scheme: scheme, large: scheme == .dark)
        }
        #endif
    }

    func testBrandTextAndFilledActionMaintainContrast() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = style
                    $0.accessibilityContrast = contrast
                }
                for color in [SnapScheduleStyle.actionUIColor, SnapScheduleStyle.emphasisUIColor] {
                    for surface in [UIColor.systemBackground, .secondarySystemGroupedBackground] {
                        XCTAssertGreaterThanOrEqual(ratio(color.resolvedColor(with: traits), surface.resolvedColor(with: traits)), 4.5)
                    }
                }
                let fill = UIColor(SnapScheduleStyle.actionFill).resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(ratio(fill, .white), 4.5)
                XCTAssertGreaterThanOrEqual(ratio(SnapScheduleStyle.calendarUIColor.resolvedColor(with: traits), .white), 4.5)
            }
        }
    }

    func testProductScreensRenderWithLocalizedControlsAndIsolatedData() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Design Simulator only")
        #else
        let designDevices = ["DC2BEFD2-98F0-477B-AB32-294F8E659FCA", "9713C13F-7AB6-47F8-883A-FBF7125B1B3F"]
        guard ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              designDevices.contains(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? ""),
              case .disabled = AdsConfiguration.current.state else {
            throw XCTSkip("Explicit unconfigured Task42-1 design runner required")
        }
        XCTAssertFalse(AdsConsentManager.shared.canRequestAds)
        let container = try SnapScheduleModelContainer.makeInMemory()
        let day = CalendarDate.gregorianDate(from: .now)
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "design-synthetic", sourceCandidateKey: "design",
            evidenceText: "2026.10 · 18:30 · Seoul", title: "디자인 리뷰", date: day,
            time: ClockTime(hour: 18, minute: 30), timeZoneIdentifier: "Asia/Seoul")
        let schedule = Schedule(sourceCandidateID: UUID(), title: "디자인 리뷰", date: day,
            time: ClockTime(hour: 18, minute: 30), timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: candidate.sourceAssetIdentifier, calendarExportStatus: .succeeded)
        let second = Schedule(sourceCandidateID: UUID(), title: "팀 미팅", date: day,
            sourceAssetIdentifier: candidate.sourceAssetIdentifier)
        container.mainContext.insert(candidate)
        container.mainContext.insert(schedule)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let suite = "task421-design-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        let photo = PhotoAuthorizationService(statusProvider: { .denied }, authorizationRequester: {
            XCTFail("Rendering must not request photo permission"); return .denied
        })
        let notifications = NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in
            XCTFail("Rendering must not request notification permission"); return false
        })
        await notifications.refresh()
        let scheduler = NotificationScheduler(center: DesignNotificationCenter())
        let data = try XCTUnwrap(sourceImage().pngData())
        let factory: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
            ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in ScreenshotImageInput(data: data, orientation: .up) }
        }
        // String(localized:) follows the process language, not SwiftUI's date-formatting locale.
        // Run this exact test with -testLanguage ko/en/ja instead of mislabeling environment-only renders.
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let arguments = ProcessInfo.processInfo.arguments
        let screenFilter: Set<String>? = arguments.firstIndex(of: "-Task421ScreenFilter").flatMap { index in
            arguments.indices.contains(index + 1) ? Set(arguments[index + 1].split(separator: ",").map(String.init)) : nil
        }
        let cases: [(String, ColorScheme, DynamicTypeSize)] = screenFilter == nil
            ? [(language, .light, .large), (language, .dark, .large), (language, .dark, .accessibility3)]
            : [(language, .light, .large), (language, .dark, .accessibility3)]
        for (language, scheme, typeSize) in cases {
            let locale = Locale(identifier: language)
            let scan = ScanCoordinator(context: container.mainContext, settings: settings,
                discover: { screenFilter == nil ? .unavailable($0) : .authorized([]) },
                loadImage: { _, _ in throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in [] })
            defer { scan.cancel() }
            let galleryNavigation = AppTabNavigation(); galleryNavigation.tab = .candidates
            let galleryPhoto = PhotoAuthorizationService(statusProvider: { .authorized }, authorizationRequester: {
                XCTFail("Synthetic rendering must not request Photos permission"); return .authorized
            })
            let gallery = screenFilter == nil
                ? AnyView(NavigationStack { CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in }) })
                : AnyView(HomeView(scanCoordinator: scan, notificationNavigation: NotificationNavigationStore(),
                    notificationAuthorization: notifications, notificationScheduler: scheduler, photoAuthorization: galleryPhoto,
                    navigation: galleryNavigation))
            let screens: [(String, AnyView)] = [
                ("home", AnyView(HomeView(scanCoordinator: scan, notificationNavigation: NotificationNavigationStore(),
                    notificationAuthorization: notifications, notificationScheduler: scheduler))),
                ("gallery", gallery),
                ("candidate", AnyView(NavigationStack { CandidateDetailView(candidate: candidate)
                    .navigationTitle(String(localized: "Candidate", locale: locale)).navigationBarTitleDisplayMode(.inline) })),
                ("detail", AnyView(NavigationStack { ScheduleDetailView(schedule: schedule, notificationAuthorization: notifications,
                    notificationScheduler: scheduler).navigationTitle(String(localized: "Schedule", locale: locale)).navigationBarTitleDisplayMode(.inline) })),
                ("edit", AnyView(NavigationStack { ScheduleEditView(schedule: schedule) })),
                ("settings", AnyView(SettingsView(notificationAuthorization: notifications, managesNotificationAuthorization: false,
                    photoAuthorization: photo, settings: settings, calendarAccessProvider: { .denied }, showsDismissButton: screenFilter == nil)))
            ]
            for (name, screen) in screens {
                if let screenFilter, !screenFilter.contains(name) { continue }
                try await render(screen.modelContainer(container).environment(\.locale, locale)
                    .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, typeSize)
                    .environment(\.scenePhase, .active)
                    .environment(\.screenshotThumbnailFactory, factory).environment(\.screenshotPreviewFactory, factory)
                    .environment(\.screenshotCalendarThumbnailFactory, factory).tint(SnapScheduleStyle.action),
                    name: "\(language)-\(scheme)-\(typeSize.isAccessibilitySize ? "large-" : "")\(name)", scheme: scheme, large: typeSize.isAccessibilitySize)
            }
            let presentations = [schedule, second].map {
                WidgetSchedulePresentation(id: $0.id, title: $0.title, date: WidgetCalendarDate(year: day.year, month: day.month, day: day.day),
                    time: nil, timeZoneIdentifier: "Asia/Seoul", dDayText: "D-Day")
            }
            let plan = WidgetTimelinePlan(contentState: .schedules, presentations: presentations, nextRefreshDate: nil)
            for family in screenFilter == nil ? [WidgetFamily.systemSmall, .systemMedium] : [] {
                try await render(UpcomingScheduleWidgetContent(family: family, plan: plan)
                    .environment(\.locale, locale).environment(\.colorScheme, scheme)
                    .padding(16).background(Color(uiColor: .systemBackground))
                    .frame(width: family == .systemSmall ? 155 : 329, height: 155)
                    .ignoresSafeArea(),
                    name: "\(language)-\(scheme)-widget-\(family)", scheme: scheme, large: false,
                    size: CGSize(width: family == .systemSmall ? 155 : 329, height: 155))
            }
        }
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(schedule.title, "디자인 리뷰")
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 2)
        XCTAssertEqual([settings.reminderDayBefore, settings.reminderSameDay, settings.defaultExportToCalendar], [true, true, false])
        let needsReview = ScheduleCandidate(sourceAssetIdentifier: candidate.sourceAssetIdentifier, sourceCandidateKey: "disabled",
            title: "Review needed", date: day, time: ClockTime(hour: 18, minute: 30),
            timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.timeZoneInferred])
        try await render(NavigationStack { CandidateDetailView(candidate: needsReview) }
            .modelContainer(container).environment(\.colorScheme, .dark).environment(\.scenePhase, .active)
            .environment(\.screenshotPreviewFactory, factory),
            name: "\(language)-dark-candidate-disabled", scheme: .dark, large: false)
        if screenFilter != nil {
            try await render(Form { ScreenshotInlineSection(sourceScreenshotIdentifier: "unavailable-fixture") }
                .environment(\.scenePhase, .active)
                .environment(\.screenshotPreviewFactory, { id in
                    ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in throw ScreenshotImageLoadError.inaccessible }
                }), name: "\(language)-original-unavailable", scheme: .light, large: false)
            try await render(ScreenshotPreviewView(model: factory("zoom-fixture")),
                name: "\(language)-original-zoom", scheme: .light, large: false)
            schedule.calendarExportStatus = .unknown
            try await render(NavigationStack { ScheduleDetailView(schedule: schedule,
                notificationAuthorization: notifications, notificationScheduler: scheduler) }
                .modelContainer(container).environment(\.dynamicTypeSize, .accessibility3)
                .environment(\.scenePhase, .active).environment(\.screenshotPreviewFactory, factory),
                name: "\(language)-dark-large-detail-unknown", scheme: .dark, large: true)
            schedule.calendarExportStatus = .succeeded
        }
        #endif
    }

    // Native UIKit toolbar items use UIControl/target-action rather than the SwiftUI
    // virtual element's accessibilityActivate. Exercise the same attached button action.
    private func activateReviewButton(_ object: NSObject, in root: UIView) -> Bool {
        if object.accessibilityActivate() { return true }
        print("Activate \(type(of: object)) \(object.accessibilityLabel ?? "nil")")
        if let control = object as? UIControl {
            control.sendActions(for: .touchUpInside); return true
        }
        if let item = object as? UIBarButtonItem, let action = item.action {
            return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        }
        if let control = descendantsForResponsive(root).compactMap({ $0 as? UIControl }).first(where: {
            $0.accessibilityLabel == object.accessibilityLabel && object.accessibilityLabel != nil
        }) {
            control.sendActions(for: .touchUpInside); return true
        }
        func dialog(in controller: UIViewController?) -> UIAlertController? {
            guard let controller else { return nil }
            if let alert = controller as? UIAlertController { return alert }
            if let result = dialog(in: controller.presentedViewController) { return result }
            return controller.children.compactMap { dialog(in: $0) }.first
        }
        if let alert = dialog(in: root.window?.rootViewController),
           let action = alert.actions.first(where: { $0.title == object.accessibilityLabel }),
           let callback = action.value(forKey: "handler") {
            typealias Handler = @convention(block) (UIAlertAction) -> Void
            let handler = unsafeBitCast(callback as AnyObject, to: Handler.self)
            alert.dismiss(animated: false)
            handler(action)
            return true
        }
        print("Unactivated native button: \(type(of: object)), \(object.accessibilityLabel ?? "nil")")
        return false
    }

    private func pairingIdentifier(_ object: NSObject) -> String? {
        let key=NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to:key) ? object.perform(key)?.takeUnretainedValue() as? String:nil
    }

    private func render<V: View>(_ screen: V, name: String, scheme: ColorScheme, large: Bool, size: CGSize? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let controller = UIHostingController(rootView: screen)
        controller.traitOverrides.accessibilityContrast = large ? .high : .normal
        controller.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraExtraLarge : .large
        let window = UIWindow(windowScene: scene)
        window.frame = size.map { CGRect(origin: .zero, size: $0) } ?? UIScreen.main.bounds
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        attach(controller.view, name: name + "-top")
        if let scroll = firstScroll(controller.view) {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "Horizontal overflow in \(name)")
            // Keep the bottom original and registration action reviewable in the captured product views.
            if name.contains("candidate") || name.contains("detail") || name.contains("edit")
                || (name.hasPrefix("pairing-") && name.contains("-gallery-")) {
                // The lazily loaded original changes Form's estimated row heights.
                // Resolve the end after loading so the capture includes the original itself.
                for _ in 0..<4 {
                    let bottom = max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    try await Task.sleep(for: .milliseconds(250))
                }
                attach(controller.view, name: name + "-bottom")
            }
        }
    }

    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "task421-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func firstScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScroll).first
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func sourceImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.systemGray6.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            ("DESIGN REVIEW\n\n2026.10\n18:30 · Seoul\n\nSYNTHETIC SOURCE" as NSString).draw(
                in: CGRect(x: 20, y: 45, width: 260, height: 310),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: UIColor.label])
        }
    }

    private func ratio(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let channels = [r, g, b].map { value in
                let s = Double(value); return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

@MainActor
private final class DesignNotificationCenter: NotificationCenterScheduling {
    func pendingRequests() async -> [UNNotificationRequest] { [] }
    func add(_ request: UNNotificationRequest) async throws { XCTFail("Rendering must not schedule reminders") }
    func removePendingRequests(withIdentifiers identifiers: [String]) {}
}
