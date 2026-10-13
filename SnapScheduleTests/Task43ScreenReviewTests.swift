import Darwin
import Photos
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import Vision
import WidgetKit
import XCTest
@testable import SnapSchedule

/// Actual product views. Only the explicitly isolated, ad-disabled Simulator runner can inspect them.
@MainActor
final class Task43ScreenReviewTests: XCTestCase {
    private struct Viewport {
        let name: String
        let size: CGSize
        let large: Bool
        let dark: Bool
    }
    private let viewports = [
        Viewport(name: "SE-light", size: CGSize(width: 375, height: 667), large: false, dark: false),
        Viewport(name: "SE-AX5-dark-reduceMotion", size: CGSize(width: 375, height: 667), large: true, dark: true),
        Viewport(name: "Plus-dark", size: CGSize(width: 428, height: 926), large: false, dark: true),
        Viewport(name: "landscape-light", size: CGSize(width: 667, height: 375), large: false, dark: false)
    ]

    func testFinalCoreScreenLayouts() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = makeCandidate("editor")
        candidate.dateEntries = [
            CandidateDateEntry(date: candidate.date, time: ClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Asia/Seoul", reviewReasons: [.uncertainTimeAssociation]),
            CandidateDateEntry(date: CalendarDate(year: 2027, month: 1, day: 20), timeZoneIdentifier: "America/Los_Angeles")
        ]
        candidate.recognizedDateOptions = candidate.dateEntries
        let schedule = Schedule(sourceCandidateID: UUID(), title: String(repeating: String(localized: "Appointment") + " ", count: 6),
            date: CalendarDate(year: 2027, month: 1, day: 18), time: ClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: "synthetic", notifyDayBefore: true, calendarExportStatus: .failed)
        container.mainContext.insert(candidate); container.mainContext.insert(schedule); try container.mainContext.save()
        let suite = "task43-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        let notifications = notificationService(); await notifications.refresh()
        let scheduler = NotificationScheduler(center: Task43NotificationCenter())
        let scanner = ScanCoordinator(context: container.mainContext, settings: settings,
            discover: { _ in .authorized([]) }, loadImage: { _, _ in XCTFail("No PhotoKit"); throw ScreenshotImageLoadError.inaccessible }, recognizeText: { _ in XCTFail("No OCR"); return [] })
        defer { scanner.cancel() }
        let navigation = AppTabNavigation()
        let home = HomeView(scanCoordinator: scanner, notificationNavigation: NotificationNavigationStore(),
            notificationAuthorization: notifications, notificationScheduler: scheduler,
            photoAuthorization: photoService(.authorized), navigation: navigation)
        let screens: [(String, AnyView, [String])] = [
            ("home-ad-absent", AnyView(home), ["Home", "Candidate review", "Settings"]),
            ("gallery-review", AnyView(NavigationStack { CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in }) }), ["Source photos", "Review needed", "Ready to register"]),
            ("candidate", AnyView(NavigationStack { CandidateDetailView(candidate: candidate, notificationAuthorization: notifications, notificationScheduler: scheduler).navigationTitle(String(localized: "Candidate")).navigationBarTitleDisplayMode(.inline) }), ["Add date +", "Remove date", "All-day", "Choose a recognized date"]),
            ("schedule-detail-failed", AnyView(NavigationStack { ScheduleDetailView(schedule: schedule, notificationAuthorization: notifications, notificationScheduler: scheduler).navigationTitle(String(localized: "Schedule")).navigationBarTitleDisplayMode(.inline) }), ["Try Again", "Delete Schedule", "Edit"]),
            ("schedule-edit", AnyView(NavigationStack { ScheduleEditView(schedule: schedule, notificationAuthorization: notifications, notificationScheduler: scheduler) }), ["Include time", "Save", "Cancel"]),
            ("settings-denied", AnyView(SettingsView(notificationAuthorization: notifications, managesNotificationAuthorization: false, photoAuthorization: photoService(.denied), settings: settings, calendarAccessProvider: { .denied }, showsDismissButton: false)), ["Day before", "Same day", "Open App Settings"])
        ]
        for viewport in viewports {
            for (name, screen, required) in screens {
                let labels = try await review(screen.modelContainer(container), name: name, viewport: viewport)
                for key in required { XCTAssertTrue(labels.contains { $0.contains(String(localized: String.LocalizationValue(key))) }, "Missing \(key) in \(name)/\(viewport.name)") }
            }
        }
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(candidate.dateEntries.count, 2)
        XCTAssertEqual(schedule.calendarExportStatus, .failed)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 1)
        XCTAssertFalse(AdsConsentManager.shared.canRequestAds)
    }

    func testFinalEmptyManyAnalysisPermissionAndOriginalStates() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        for viewport in [viewports[0], viewports[1]] {
            _ = try await review(NavigationStack { CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in }) }.modelContainer(container), name: "candidates-zero", viewport: viewport)
            for status in [PHAuthorizationStatus.notDetermined, .limited, .denied, .restricted] {
                _ = try await review(Form { PhotoAccessView(authorization: photoService(status)) }, name: "photo-\(status.rawValue)", viewport: viewport)
            }
            for state in [ScanRunState.waiting, .discovering, .analyzing, .completed, .completedWithFailures, .failed, .accessUnavailable] {
                let status = ScanStatus(state: state, photoAccess: state == .accessUnavailable ? .limited : .authorized,
                    targetImageCount: state == .completed ? 0 : 120, completedImageCount: 99, failedImageCount: state == .failed || state == .completedWithFailures ? 2 : 0, pendingImageCount: 19)
                _ = try await review(Form { Section { HomeScanStatusView(status: status) }; Section { ScanStatusView(status: status, candidateSummary: CandidateReviewSummary(candidates: [])) } }, name: "scan-\(state)", viewport: viewport)
            }
            _ = try await review(Form { ScreenshotInlineSection(sourceScreenshotIdentifier: "inaccessible") }, name: "original-unavailable", viewport: viewport)
            _ = try await review(ScreenshotPreviewView(model: imageFactory("synthetic")), name: "original-viewer", viewport: viewport)
        }
        for index in 0..<120 { container.mainContext.insert(makeCandidate("many-\(index)", review: index % 2 == 0)) }
        try container.mainContext.save()
        for viewport in [viewports[0], viewports[1], viewports[3]] {
            _ = try await review(NavigationStack { CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in },
                reviewPresentation: CandidateReviewPresentation(candidates: try! container.mainContext.fetch(FetchDescriptor<ScheduleCandidate>()))) }.modelContainer(container), name: "candidates-120", viewport: viewport, entireScroll: false)
        }
        let candidates = try container.mainContext.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).pendingCount, 120)
        XCTAssertEqual(CandidateReviewSummary(candidates: candidates).needsReviewCount, 60)
        XCTAssertEqual(CandidateReviewPresentation(candidates: candidates).badge(scanStatus: ScanStatus()), "99+")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testFinalRegisteredOnlyWidgetSurfaces() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let schedules = (0..<3).map { index in WidgetSchedulePresentation(id: UUID(), title: String(repeating: String(localized: "Appointment") + " ", count: 8),
            date: WidgetCalendarDate(year: 2027, month: 1, day: 18 + index), time: index == 0 ? nil : WidgetClockTime(hour: 14, minute: 30), timeZoneIdentifier: "Asia/Seoul", dDayText: "D-102") }
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            for state in [WidgetContentState.schedules, .empty, .unavailable] {
                for dark in [false, true] {
                    let viewport = Viewport(name: "widget-\(family)-\(state)-\(dark ? "dark" : "light")", size: CGSize(width: family == .systemSmall ? 155 : 329, height: 155), large: true, dark: dark)
                    _ = try await review(UpcomingScheduleWidgetContent(family: family, plan: WidgetTimelinePlan(contentState: state, presentations: state == .schedules ? schedules : [], nextRefreshDate: nil))
                        .padding(16).background(Color(uiColor: .systemBackground)).ignoresSafeArea(), name: "widget", viewport: viewport)
                }
            }
        }
    }

    func testFinalKeyboardDateSheetAndSaveFailure() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory(); container.mainContext.autosaveEnabled = false
        let candidate = makeCandidate("actions")
        candidate.dateEntries = [CandidateDateEntry(date: nil)]
        container.mainContext.insert(candidate); try container.mainContext.save()
        let navigation = AppTabNavigation(); navigation.tab = .candidates; navigation.candidateDetailID = candidate.id
        let host = try makeHost(NavigationStack { CandidateDetailView(candidate: candidate, notificationAuthorization: notificationService(),
            notificationScheduler: NotificationScheduler(center: Task43NotificationCenter()), navigation: navigation,
            draftSave: { _ in throw NSError(domain: "task43-synthetic-save", code: 1) }).navigationTitle(String(localized: "Candidate")).navigationBarTitleDisplayMode(.inline) }.modelContainer(container), viewport: viewports[1])
        defer { navigation.candidateWillLeave = nil; close(host) }
        try await settle(host)
        let field = try XCTUnwrap(views(host.view).compactMap { $0 as? UITextView }.first)
        let ownTitle = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { $0.accessibilityLabel == String(localized: "Enter your own title") && $0.isAccessibilityElement })
        XCTAssertTrue(activate(ownTitle, root: host.view))
        try await settle(host)
        XCTAssertTrue(field.isFirstResponder, "The product title action must focus the input")
        field.text = String(localized: "Event"); field.delegate?.textViewDidChange?(field)
        try await settle(host); capture(host.view.window!, "actions-keyboard")
        host.view.endEditing(true); try await settle(host)
        let choose = try await control("candidate-choose-date-1", host: host)
        XCTAssertGreaterThanOrEqual(choose.accessibilityFrame.height, 44)
        XCTAssertTrue(activate(choose, root: host.view)); try await settle(host)
        let picker = try XCTUnwrap(views(host.view.window!).compactMap { $0 as? UIDatePicker }.first { $0.datePickerMode == .date })
        picker.date = try XCTUnwrap(CalendarDate(year: 2027, month: 1, day: 21).foundationDate())
        picker.sendActions(for: .valueChanged); try await settle(host)
        capture(host.view.window!, "actions-date-selected")
        let dateSave = try await control("candidate-date-save", host: host)
        XCTAssertTrue(activate(dateSave, root: host.view))
        try await settle(host)
        for _ in 0..<15 where host.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(host.presentedViewController == nil || host.presentedViewController?.view.window == nil || host.presentedViewController?.isBeingDismissed == true, "The date sheet must close after Done")
        XCTAssertEqual(navigation.candidateWillLeave?(), false)
        try await settle(host); capture(host.view.window!, "actions-save-failure")
        let alert = try XCTUnwrap(dialog(host))
        XCTAssertEqual(alert.title, String(localized: "Candidate Could Not Be Saved"))
        XCTAssertEqual(candidate.dateEntries.first?.date, nil)
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testFinalRegistrationConflictFeedback() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory(); let candidate = makeCandidate("stale")
        container.mainContext.insert(candidate); try container.mainContext.save()
        let host = try makeHost(NavigationStack { CandidateDetailView(candidate: candidate, notificationAuthorization: notificationService(), notificationScheduler: NotificationScheduler(center: Task43NotificationCenter())) }.modelContainer(container), viewport: viewports[0])
        defer { close(host) }; try await settle(host)
        // The real registration button must reject a candidate ignored in a newer context.
        let fresh = ModelContext(container); let persisted = try XCTUnwrap(fresh.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        persisted.reviewStatus = .dismissed; try fresh.save()
        let register = try await control("candidate-register", host: host)
        XCTAssertTrue(activate(register, root: host.view)); try await settle(host)
        capture(host.view.window!, "actions-registration-conflict")
        XCTAssertEqual(try XCTUnwrap(dialog(host)).title, String(localized: "Candidate Needs Attention"))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testFinalScheduleDateDoneAndValidationError() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let schedule = Schedule(sourceCandidateID: UUID(), title: String(localized: "Appointment"), date: CalendarDate(year: 2027, month: 1, day: 18), sourceAssetIdentifier: "synthetic")
        container.mainContext.insert(schedule); try container.mainContext.save()
        let host = try makeHost(NavigationStack { ScheduleEditView(schedule: schedule, notificationAuthorization: notificationService(), notificationScheduler: NotificationScheduler(center: Task43NotificationCenter())) }.modelContainer(container), viewport: viewports[0])
        defer { close(host) }; try await settle(host)
        let date = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { $0.accessibilityLabel == String(localized: "Date") && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
        XCTAssertTrue(activate(date, root: host.view)); try await settle(host)
        let picker = try XCTUnwrap(views(host.view.window!).compactMap { $0 as? UIDatePicker }.first { $0.datePickerMode == .date })
        picker.date = try XCTUnwrap(CalendarDate(year: 2027, month: 1, day: 22).foundationDate())
        picker.sendActions(for: .valueChanged); try await settle(host); capture(host.view.window!, "schedule-date-selected")
        let sheet = try XCTUnwrap(host.presentedViewController)
        let done = try XCTUnwrap(PresentationAutomationScope.objects(in: sheet.view).first { $0.accessibilityLabel == String(localized: "Done") && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
        XCTAssertTrue(activate(done, root: host.view))
        for _ in 0..<20 where host.presentedViewController != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(host.presentedViewController == nil || host.presentedViewController?.view.window == nil || host.presentedViewController?.isBeingDismissed == true)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2027, month: 1, day: 18), "Done changes the draft; Save commits the schedule")
        let field = try XCTUnwrap(views(host.view).compactMap { $0 as? UITextView }.first)
        field.text = "   "; field.delegate?.textViewDidChange?(field); try await settle(host)
        let save = try XCTUnwrap(PresentationAutomationScope.objects(in: host.view).first { $0.accessibilityLabel == String(localized: "Save") && $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) })
        XCTAssertTrue(activate(save, root: host.view)); try await settle(host)
        let error = try XCTUnwrap(dialog(host)); capture(host.view.window!, "schedule-validation-error")
        XCTAssertEqual(error.title, String(localized: "Schedule Could Not Be Saved"))
        XCTAssertEqual(schedule.title, String(localized: "Appointment")); XCTAssertEqual(schedule.date, CalendarDate(year: 2027, month: 1, day: 18))
    }

    func testEnglishMaximumTextHeadingsAreFullyDrawn() async throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        guard Locale.current.language.languageCode?.identifier == "en" else { throw XCTSkip("English visual regression") }
        let container = try SnapScheduleModelContainer.makeInMemory(); let candidate = makeCandidate("heading")
        container.mainContext.insert(candidate); try container.mainContext.save()
        let host = try makeHost(NavigationStack { CandidateDetailView(candidate: candidate, notificationAuthorization: notificationService(), notificationScheduler: NotificationScheduler(center: Task43NotificationCenter()))
            .navigationTitle(String(localized: "Candidate")).navigationBarTitleDisplayMode(.inline) }.modelContainer(container), viewport: viewports[1])
        defer { close(host) }; try await settle(host)
        let count = try await control("candidate-date-count", host: host)
        let scroll = try XCTUnwrap(views(host.view).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) })
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + count.accessibilityFrame.minY - 140), animated: false)
        try await settle(host); capture(host.view, "english-AX5-headings")
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        let words = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        print("[Task43 heading pixels] " + words)
        XCTAssertTrue(words.localizedCaseInsensitiveContains("Notifications"), "The section heading must be drawn fully, not ellipsized: " + words)
        XCTAssertTrue(words.localizedCaseInsensitiveContains("Review schedule"), "The native navigation title must fit beside the registration action: " + words)
    }

    private func makeCandidate(_ id: String, review: Bool = false) -> ScheduleCandidate {
        ScheduleCandidate(sourceAssetIdentifier: "task43-" + id, sourceCandidateKey: id,
            title: String(localized: "Appointment"), date: CalendarDate(year: 2027, month: 1, day: 18),
            reviewReasons: review ? [.relativeDate] : [], notifyDayBefore: false, notifySameDay: false)
    }
    private func photoService(_ status: PHAuthorizationStatus) -> PhotoAuthorizationService {
        PhotoAuthorizationService(statusProvider: { status }, authorizationRequester: { XCTFail("No Photos permission request"); return status })
    }
    private func notificationService() -> NotificationAuthorizationService {
        NotificationAuthorizationService(statusProvider: { .denied }, authorizationRequester: { _ in XCTFail("No notification permission request"); return false })
    }
    private func imageFactory(_ id: String) -> ScreenshotPreviewModel {
        ScreenshotPreviewModel(sourceScreenshotIdentifier: id) { _, _ in
            if id == "inaccessible" { throw ScreenshotImageLoadError.inaccessible }
            let data = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 500)).image { context in
                UIColor.systemGray5.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
                ("SYNTHETIC\n2027.01.18\n14:30\nNO USER DATA" as NSString).draw(in: CGRect(x: 20, y: 30, width: 260, height: 440), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.label])
            }.pngData()!
            return ScreenshotImageInput(data: data, orientation: .up)
        }
    }
    private func makeHost<V: View>(_ view: V, viewport: Viewport) throws -> UIHostingController<AnyView> {
        let screen = view.environment(\.dynamicTypeSize, viewport.large ? .accessibility5 : .large)
            .environment(\.colorScheme, viewport.dark ? .dark : .light)
            .environment(\.scenePhase, .active).environment(\.snapCompactTypography, viewport.size.width <= 375)
            .environment(\.screenshotPreviewFactory, { id in self.imageFactory(id) }).environment(\.screenshotThumbnailFactory, { id in self.imageFactory(id) })
            .environment(\.screenshotCalendarThumbnailFactory, { id in self.imageFactory(id) })
        let motion = try Task43ReduceMotionScope(enabled: viewport.large)
        let host = UIHostingController(rootView: AnyView(screen))
        motions[ObjectIdentifier(host)] = motion
        XCTAssertEqual(UIAccessibility.isReduceMotionEnabled, viewport.large)
        host.traitOverrides.preferredContentSizeCategory = viewport.large ? .accessibilityExtraExtraExtraLarge : .large
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: viewport.size)
        window.overrideUserInterfaceStyle = viewport.dark ? .dark : .light
        window.rootViewController = host; window.makeKeyAndVisible()
        // Keep the test window alive without leaking it across review cases.
        windows[ObjectIdentifier(host)] = window
        return host
    }
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var motions: [ObjectIdentifier: Task43ReduceMotionScope] = [:]
    private func close(_ host: UIViewController) {
        windows.removeValue(forKey: ObjectIdentifier(host))?.isHidden = true
        motions.removeValue(forKey: ObjectIdentifier(host))?.restore()
    }
    private func settle(_ host: UIViewController) async throws { try await Task.sleep(for: .milliseconds(400)); host.view.layoutIfNeeded() }
    private func review<V: View>(_ view: V, name: String, viewport: Viewport, entireScroll: Bool = true) async throws -> [String] {
        print("[Task43 review start] \(Locale.current.identifier) \(viewport.name) \(name)")
        let host = try makeHost(view, viewport: viewport); defer { close(host) }
        try await settle(host)
        var labels: [String] = []; var measurements: [[String: String]] = []; var captured = Set<String>()
        let tag = "\(Locale.current.identifier)-\(viewport.name)-\(name)"
        capture(host.view, tag + "-top")
        let scroll = views(host.view).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) }
        for step in 0..<90 {
            let objects = PresentationAutomationScope.objects(in: host.view).filter(\.isAccessibilityElement)
            labels += objects.compactMap(\.accessibilityLabel)
            for id in ["candidate-time-zone-1", "candidate-time-zone-2", "candidate-add-date", "candidate-date-count"] where !captured.contains(id) {
                if let object = objects.first(where: { identifier($0) == id }), object.accessibilityFrame.minY >= 65, object.accessibilityFrame.maxY <= viewport.size.height {
                    capture(host.view, tag + "-" + id); captured.insert(id)
                }
            }
            for calendar in views(host.view).compactMap({ $0 as? UICalendarView }) {
                let frame = calendar.convert(calendar.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(frame.minX, -1); XCTAssertLessThanOrEqual(frame.maxX, viewport.size.width + 1, "Calendar outer bounds")
            }
            for object in objects where identifier(object)?.hasPrefix("candidate-") == true && object.accessibilityTraits.contains(.button) {
                let frame = object.accessibilityFrame
                measurements.append(["id": identifier(object) ?? "", "frame": NSCoder.string(for: frame), "label": object.accessibilityLabel ?? ""])
            }
            for s in views(host.view).compactMap({ $0 as? UIScrollView }) where !(s is UITextView) && !isNativeCalendarScroll(s) {
                XCTAssertLessThanOrEqual(s.contentSize.width, s.bounds.width + 1, "Horizontal overflow: \(tag)")
            }
            guard let scroll else { break }
            let maximum = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = entireScroll ? min(CGFloat(step + 1) * max(150, scroll.bounds.height * 0.7), maximum) : maximum
            if next <= scroll.contentOffset.y + 1 { break }
            scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            try await Task.sleep(for: .milliseconds(120))
            if step == 1 { capture(host.view, tag + "-middle") }
            if !entireScroll { labels += PresentationAutomationScope.objects(in: host.view).compactMap(\.accessibilityLabel); break }
        }
        capture(host.view, tag + "-bottom")
        let data = try JSONSerialization.data(withJSONObject: ["screen": tag, "labels": Array(Set(labels)).sorted(), "buttons": measurements], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "task43-" + tag + "-inspection"; attachment.lifetime = .keepAlways; add(attachment)
        print("[Task43 review end] \(tag)")
        return labels
    }
    // System month grids intentionally page horizontally. Check the calendar's outer frame separately.
    private func isNativeCalendarScroll(_ scroll: UIScrollView) -> Bool {
        var parent = scroll.superview
        while let view = parent {
            if view is UICalendarView || view is UIDatePicker { return true }
            parent = view.superview
        }
        return false
    }
    private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "task43-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func identifier(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
    }
    private func control(_ id: String, host: UIViewController) async throws -> NSObject {
        let scroll = views(host.view).compactMap { $0 as? UIScrollView }.first { !($0 is UITextView) }
        scroll?.setContentOffset(CGPoint(x: 0, y: -(scroll?.adjustedContentInset.top ?? 0)), animated: false)
        for step in 0..<80 {
            try await settle(host)
            if let object = PresentationAutomationScope.objects(in: host.view.window ?? host.view).first(where: { identifier($0) == id && $0.isAccessibilityElement }) { return object }
            if let scroll { scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step + 1) * 180), animated: false) }
        }
        XCTFail("Missing \(id)"); throw NSError(domain: "Task43MissingControl", code: 1)
    }
    private func activate(_ object: NSObject, root: UIView) -> Bool {
        if object.accessibilityActivate() { return true }
        if let button = object as? UIControl { button.sendActions(for: .touchUpInside); return true }
        if let item = object as? UIBarButtonItem, let action = item.action { return UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) }
        if let button = views(root.window ?? root).compactMap({ $0 as? UIControl }).first(where: { $0.accessibilityLabel == object.accessibilityLabel && object.accessibilityLabel != nil }) { button.sendActions(for: .touchUpInside); return true }
        return false
    }
    private func dialog(_ controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let result = dialog(presented) { return result }
        return controller.children.compactMap(dialog).first
    }
}

@MainActor
private final class Task43NotificationCenter: NotificationCenterScheduling {
    func pendingRequests() async -> [UNNotificationRequest] { [] }
    func add(_ request: UNNotificationRequest) async throws { XCTFail("No actual reminders") }
    func removePendingRequests(withIdentifiers identifiers: [String]) {}
}

// Test-runtime OS setting, restored after each isolated render; no VoiceOver support or device setting changes.
@MainActor
private final class Task43ReduceMotionScope {
    private let handle: UnsafeMutableRawPointer
    private let set: @convention(c) (Int32) -> Void
    private let previous: Int32
    init(enabled: Bool) throws {
        handle = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let getter = try XCTUnwrap(dlsym(handle, "_AXSReduceMotionEnabled"))
        let setter = try XCTUnwrap(dlsym(handle, "_AXSSetReduceMotionEnabled"))
        previous = unsafeBitCast(getter, to: (@convention(c) () -> Int32).self)()
        set = unsafeBitCast(setter, to: (@convention(c) (Int32) -> Void).self)
        set(enabled ? 1 : 0)
    }
    func restore() { set(previous); dlclose(handle) }
}
