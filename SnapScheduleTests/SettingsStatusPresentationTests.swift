import Photos
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit
import XCTest
@testable import SnapSchedule

@MainActor
final class SettingsStatusPresentationTests: XCTestCase {
    func testSettingsKeepsDefaultsAndExposesPhotoAccessAlongsidePermissions() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let suite="task421-defaults-\(UUID())"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings=AppSettings(userDefaults:defaults)
        settings.reminderDayBefore=true;settings.reminderSameDay=false;settings.defaultExportToCalendar=false
        let values=[true,false,false]
        let notification=NotificationAuthorizationService(statusProvider:{.denied},authorizationRequester:{ _ in
            XCTFail("Settings must not request notification permission");return false
        })
        let photo=PhotoAuthorizationService(statusProvider:{.denied},authorizationRequester:{
            XCTFail("Settings must not request photo permission");return .denied
        })
        for dismissButton in [false,true] {
            let controller=UIHostingController(rootView:SettingsView(notificationAuthorization:notification,
                photoAuthorization:photo,settings:settings,calendarAccessProvider:{.denied},showsDismissButton:dismissButton))
            let window=try host(controller)
            defer { window.isHidden=true }
            let seen=visitAllRows(controller.view)
            for key in ["Photo access","Day before","Same day","Preselect Apple Calendar for new schedules",
                        "Open Notification Settings","Open App Settings",
                        "Adds a separate copy to the default calendar for new events set on your iPhone. This is optional and does not sync changes from SnapSchedule."] {
                XCTAssertTrue(seen.contains {$0.contains(localized(key))},"Missing \(key): \(seen)")
            }
            attach(controller.view,name:"settings-\(dismissButton ? "sheet":"tab")-original-defaults-kept")
            XCTAssertEqual(seen.contains(localized("Done")),dismissButton,"Only sheet Settings has Done")
            XCTAssertEqual(values,[settings.reminderDayBefore,settings.reminderSameDay,settings.defaultExportToCalendar])
        }
    }

    func testSettingsPermissionMatrixPreservesGuidanceAndConditionalActions() async throws {
        let photos: [PHAuthorizationStatus] = [.notDetermined, .authorized, .limited, .denied, .restricted]
        let notifications: [UNAuthorizationStatus] = [.notDetermined, .denied, .authorized, .provisional, .ephemeral]
        let calendars: [CalendarAuthorizationAccess] = [.notDetermined, .denied, .restricted, .writeOnly, .fullAccess, .unknown]
        let suite = "task37-4-settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults)
        settings.reminderDayBefore = false
        settings.reminderSameDay = true
        settings.defaultExportToCalendar = true
        var photoRequests = 0
        var notificationRequests = 0
        let cases: [(PHAuthorizationStatus, UNAuthorizationStatus?, CalendarAuthorizationAccess)] =
            photos.map { ($0, .denied, .restricted) }
            + notifications.map { (.authorized, $0, .fullAccess) }
            + calendars.map { (.authorized, .notDetermined, $0) }
            + [(.authorized, nil, .unknown)]
        for (index, value) in cases.enumerated() {
            let photo = PhotoAuthorizationService(statusProvider: { value.0 }, authorizationRequester: {
                photoRequests += 1; return value.0
            })
            let notification = NotificationAuthorizationService(statusProvider: { value.1 ?? .notDetermined },
                authorizationRequester: { _ in notificationRequests += 1; return false })
            if value.1 != nil { await notification.refresh() }
            let large = index % 2 == 0
            try review(SettingsView(notificationAuthorization: notification, managesNotificationAuthorization: false,
                photoAuthorization: photo, settings: settings, calendarAccessProvider: { value.2 }),
                name: "settings-state-\(index)", large: large) { view in
                let seen = visitAllRows(view)
                for key in ["Day before", "Same day", "Preselect Apple Calendar for new schedules", "Photo access", "Done",
                            "This preselects export for new candidates. Permission is requested only after registration.",
                            "Date-only schedules are all-day events; timed schedules last one hour. Calendar alarms, screenshots, and OCR text are never included.",
                            "Calendar copies may sync through your selected account and are not updated or deleted when you change SnapSchedule."] {
                    XCTAssertTrue(seen.contains { $0.contains(localized(key)) }, "State \(index) missing \(key): \(seen.sorted())")
                }
                XCTAssertTrue(seen.contains { $0.contains(notification.access.displayName) })
                XCTAssertTrue(seen.contains { $0.contains(notification.access.guidance) })
                XCTAssertTrue(seen.contains { $0.contains(value.2.displayName) })
                XCTAssertEqual(seen.contains { $0.contains(localized("Open Notification Settings")) }, notification.access.canOpenSystemSettings)
                XCTAssertEqual(seen.contains { $0.contains(localized("Open App Settings")) }, value.2 == .denied || value.2 == .restricted)
                XCTAssertEqual(seen.contains { $0.contains(localized("Manage Selected Photos")) }, value.0 == .limited)
                XCTAssertEqual(seen.contains { $0 == localized("Continue") }, value.0 == .notDetermined)
                attach(view, name: "settings-state-\(index)-photos")
            }
        }
        XCTAssertEqual(photoRequests, 0)
        XCTAssertEqual(notificationRequests, 0)
        XCTAssertFalse(settings.reminderDayBefore)
        XCTAssertTrue(settings.reminderSameDay)
        XCTAssertTrue(settings.defaultExportToCalendar)
        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual([restored.reminderDayBefore, restored.reminderSameDay, restored.defaultExportToCalendar], [false, true, true])
    }

    func testPhotoGuidanceAndActionsRemainReadableAtLargestType() throws {
        let cases: [(PHAuthorizationStatus, String)] = [
            (.notDetermined, "Find schedules in screenshots"), (.authorized, "Full Photos access"),
            (.limited, "Limited Photos access"), (.denied, "Photos access is off"), (.restricted, "Photos access is restricted")
        ]
        for (status, title) in cases {
            let authorization = PhotoAuthorizationService(statusProvider: { status }, authorizationRequester: { status })
            try review(ScrollView { PhotoAccessView(authorization: authorization).padding() }
                .environment(\.dynamicTypeSize, .accessibility5), name: "photo-\(status.rawValue)", large: true) { view in
                let seen = visitAllRows(view)
                XCTAssertTrue(seen.contains { $0.contains(localized(title)) })
                if status == .limited {
                    for key in ["Manage Selected Photos", "Open Settings"] {
                        XCTAssertTrue(seen.contains { $0.contains(localized(key)) })
                    }
                }
            }
        }
    }

    func testScanStatesKeepBatchAndCandidateCountsSeparate() throws {
        let states: [(ScanRunState, String, String)] = [
            (.waiting, "Waiting to analyze", "Analysis resumes the next time the app becomes active."),
            (.discovering, "Finding screenshots", "The first scan may take a while. You can keep using the app."),
            (.analyzing, "Analyzing screenshots", "You can keep using saved results while analysis continues."),
            (.completed, "Analysis complete", "All images in this batch were processed."),
            (.completedWithFailures, "Analysis completed with failures", "Temporary failures will be retried on the next activation."),
            (.failed, "Analysis stopped", "Analysis will try again on the next activation."),
            (.accessUnavailable, "Photo access required", "Allow photo access to analyze screenshots automatically.")
        ]
        let summary = CandidateReviewSummary(candidates: [])
        for (index, value) in states.enumerated() {
            let status = ScanStatus(state: value.0, photoAccess: index % 2 == 0 ? .limited : .authorized,
                targetImageCount: 10, completedImageCount: 6, failedImageCount: 1, pendingImageCount: 3)
            try review(ScrollView { ScanStatusView(status: status, candidateSummary: summary).padding() },
                name: "analysis-\(index)", large: index % 2 == 0) { view in
                let seen = visitAllRows(view)
                for key in [value.1, value.2, "Current batch", "Target", "Completed", "Failed", "Remaining",
                            "Pending candidates (all batches)", "Review needed", "Ready to register"] {
                    XCTAssertTrue(seen.contains { $0.contains(localized(key)) }, "State \(index) missing \(key): \(seen.sorted())")
                }
                for count in [10, 6, 1, 3] { XCTAssertTrue(seen.contains { $0.contains(count.formatted()) }) }
            }
        }
        let variants: [(ScanStatus, String)] = [
            (ScanStatus(state: .completed, photoAccess: .authorized), "No new screenshots to analyze."),
            (ScanStatus(state: .analyzing, photoAccess: .limited, imageLoadPhase: .downloadingFromICloud(progress: 0.42)), String(localized: "Downloading from iCloud \(42)%")),
            (ScanStatus(state: .failed, photoAccess: .authorized, lastErrorMessage: "SYNTHETIC ERROR"), "SYNTHETIC ERROR")
        ]
        for (index, value) in variants.enumerated() {
            try review(ScrollView { ScanStatusView(status: value.0, candidateSummary: summary).padding() },
                name: "analysis-extra-\(index)", large: true) { view in
                XCTAssertTrue(visitAllRows(view).contains { $0.contains(localized(value.1)) })
            }
        }
    }

    func testOriginalStatesShareGuidanceAndRetryAction() throws {
        let cases: [(ScreenshotPreviewStatus, String, String?)] = [
            (.idle, "Loading screenshot…", nil), (.loadingLocal, "Loading screenshot…", nil),
            (.downloadingFromICloud(progress: 0.42), "Downloading original from iCloud…", nil),
            (.retryable(.local), "Screenshot Could Not Be Loaded", "The original could not be loaded. Please try again."),
            (.retryable(.iCloud), "Screenshot Could Not Be Loaded", "The original could not be downloaded from iCloud. Check your connection and try again."),
            (.inaccessible, "Screenshot Unavailable", "The original may have been deleted, removed from limited access, or made unavailable by Photos permission changes. Your saved candidate or schedule is unchanged.")
        ]
        for (index, value) in cases.enumerated() {
            var retries = 0
            try review(ScrollView { ScreenshotImageStatusView(status: value.0, onRetry: { retries += 1 }).padding() },
                name: "original-state-\(index)", large: index % 2 == 0) { view in
                let seen = visitAllRows(view)
                XCTAssertTrue(seen.contains { $0.contains(localized(value.1)) })
                if let message = value.2 {
                    XCTAssertTrue(seen.contains { $0.contains(localized(message)) })
                    let retry = try XCTUnwrap(objects(view).first { $0.accessibilityLabel == localized("Try Again") })
                    XCTAssertTrue(retry.accessibilityActivate())
                    XCTAssertEqual(retries, 1)
                } else {
                    XCTAssertFalse(seen.contains { $0.contains(localized("Try Again")) })
                }
            }
        }
    }

    func testFullScreenAndInlineOriginalsRenderActualLoadingAndFailureStates() throws {
        let cases: [(ScreenshotPreviewStatus, String)] = [
            (.loadingLocal, "Loading screenshot…"),
            (.downloadingFromICloud(progress: 0.42), "Downloading original from iCloud…"),
            (.retryable(.local), "Screenshot Could Not Be Loaded"),
            (.retryable(.iCloud), "Screenshot Could Not Be Loaded"),
            (.inaccessible, "Screenshot Unavailable")
        ]
        for (index, value) in cases.enumerated() {
            for fullscreen in [false, true] {
            let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: "synthetic-state-\(index)") { _, onPhase in
                switch value.0 {
                case .loadingLocal:
                    try await Task.sleep(for: .seconds(60))
                case let .downloadingFromICloud(progress):
                    onPhase(.downloadingFromICloud(progress: progress))
                    try await Task.sleep(for: .seconds(60))
                case let .retryable(source):
                    throw ScreenshotImageLoadError.retryable(source)
                default:
                    throw ScreenshotImageLoadError.inaccessible
                }
                throw ScreenshotImageLoadError.cancelled
            }
            defer { model.cancel() }
                let screen: AnyView = fullscreen
                    ? AnyView(ScreenshotPreviewView(model: model))
                    : AnyView(NavigationStack {
                        Form { ScreenshotInlineSection(sourceScreenshotIdentifier: model.sourceScreenshotIdentifier) }
                    }.environment(\.screenshotPreviewFactory, { _ in model }))
                try review(screen, name: "original-\(fullscreen ? "fullscreen" : "inline")-\(index)", large: index % 2 == 1) { view in
                    let seen = visitAllRows(view)
                    XCTAssertTrue(seen.contains { $0.contains(localized(value.1)) })
                    XCTAssertEqual(model.status, value.0, "fullscreen=\(fullscreen), case=\(index)")
                    XCTAssertNil(model.image)
                    if index >= 2 { XCTAssertTrue(seen.contains { $0.contains(localized("Try Again")) }) }
                    attach(view, name: "original-\(fullscreen ? "fullscreen" : "inline")-\(index)-resolved")
                }
            }
        }
    }

    func testGalleryOriginalKeepsFailureStateAndSeparateActions() throws {
        for source in [ScreenshotImageLoadSource.local, .iCloud] {
            let candidate = ScheduleCandidate(sourceAssetIdentifier: "synthetic-gallery-state", sourceCandidateKey: "state",
                title: "SYNTHETIC CANDIDATE", date: CalendarDate(year: 2026, month: 10, day: 5))
            let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: candidate.sourceAssetIdentifier) { _, _ in
                if source == .local { throw ScreenshotImageLoadError.inaccessible }
                throw ScreenshotImageLoadError.retryable(.iCloud)
            }
            var opens = 0
            var ignores = 0
            try review(CandidateGalleryCard(candidate: candidate, imageHeight: 240,
                onOpen: { opens += 1 }, onIgnore: { ignores += 1 })
                .padding().environment(\.screenshotThumbnailFactory, { _ in model }),
                name: "gallery-original-state-\(source)", large: false) { view in
                let original = try XCTUnwrap(objects(view).first { $0.isAccessibilityElement &&
                    $0.accessibilityLabel?.hasPrefix(localized("Original screenshot")) == true })
                XCTAssertEqual(model.status, source == .local ? .inaccessible : .retryable(.iCloud))
                XCTAssertNil(model.image)
                XCTAssertTrue(original.accessibilityActivate())
                XCTAssertEqual(opens, 1)
                XCTAssertEqual(ignores, 0)
                let ignore = try XCTUnwrap(objects(view).first { $0.isAccessibilityElement &&
                    $0.accessibilityLabel?.contains(String(localized: "Ignore actions for \(candidate.title)")) == true })
                XCTAssertTrue(ignore.accessibilityActivate())
                XCTAssertEqual(ignores, 1)
                XCTAssertEqual(candidate.reviewStatus, .pending)
            }
            model.cancel()
        }
    }

    func testWidgetSizesPreserveScheduleIdentityAndStates() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let schedules = (1...3).map { index in
            WidgetSchedulePresentation(id: UUID(), title: localized("Event") + " \(index) — SYNTHETIC LONG TITLE",
                date: WidgetCalendarDate(year: 2026, month: 10, day: 5 + index),
                time: index == 2 ? nil : WidgetClockTime(hour: 18, minute: 30), timeZoneIdentifier: "Asia/Seoul", dDayText: "D-\(index)")
        }
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            for large in [false, true] {
                for state in [WidgetContentState.schedules, .empty, .unavailable] {
                    var opened: [URL] = []
                    let plan = WidgetTimelinePlan(contentState: state, presentations: state == .schedules ? schedules : [], nextRefreshDate: nil)
                    let width: CGFloat = family == .systemSmall ? 155 : 329
                    let widget = UpcomingScheduleWidgetContent(family: family, plan: plan)
                        .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
                        .padding(16).frame(width: width, height: 155)
                        .background(Color(uiColor: .systemBackground))
                    try review(widget, name: "widget-\(family)-\(state)", large: large) { view in
                        attachWidget(view, size: CGSize(width: width, height: 155),
                            name: "widget-content-\(family)-\(state)-\(large ? "large-dark" : "light")")
                        let seen = labels(view)
                        if state == .schedules {
                            for schedule in schedules.prefix(family == .systemSmall ? 1 : 3) {
                                XCTAssertTrue(seen.contains { $0.contains(schedule.title) })
                                XCTAssertTrue(seen.contains { $0.contains(schedule.dDayText) })
                                if family == .systemMedium {
                                    let link = try XCTUnwrap(objects(view).first { $0.isAccessibilityElement && $0.accessibilityLabel?.contains(schedule.title) == true })
                                    XCTAssertTrue(link.accessibilityActivate())
                                    XCTAssertEqual(opened.last, WidgetScheduleLink.url(for: schedule.id))
                                }
                            }
                        } else {
                            XCTAssertTrue(seen.contains { $0.contains(localized(state == .empty ? "No upcoming schedules" : "Schedules unavailable")) })
                            XCTAssertTrue(seen.contains { $0.contains(localized(state == .empty ? "Registered schedules will appear here." : "Open SnapSchedule to refresh the widget.")) })
                        }
                    }
                }
            }
        }
    }

    private func review<V: View>(_ view: V, name: String, large: Bool, check: (UIView) throws -> Void) throws {
        let controller = UIHostingController(rootView: view
            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            .environment(\.colorScheme, large ? .dark : .light))
        controller.overrideUserInterfaceStyle = large ? .dark : .light
        controller.view.backgroundColor = .systemBackground
        controller.traitOverrides.accessibilityContrast = large ? .high : .normal
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = try host(controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        attach(controller.view, name: "\(name)-\(large ? "large-dark-contrast" : "light")")
        try check(controller.view)
    }

    private func attachWidget(_ view: UIView, size: CGSize, name: String) {
        let origin = CGPoint(x: (view.bounds.width - size.width) / 2, y: (view.bounds.height - size.height) / 2)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: -origin.x, y: -origin.y)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(Locale.current.identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "\(name)-\(Locale.current.identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func objects(_ view: UIView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            object.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(collect)
            if let view = object as? UIView { view.subviews.forEach(collect) }
        }
        collect(view)
        return result
    }

    private func localized(_ key: String) -> String { String(localized: String.LocalizationValue(key)) }

    private func host<V: View>(_ controller: UIHostingController<V>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
        return window
    }

    private func visitAllRows(_ view: UIView) -> Set<String> {
        var result = Set(labels(view))
        guard let scroll = firstScroll(view) else { return result }
        var offset = -scroll.adjustedContentInset.top
        while offset < scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            settle()
            result.formUnion(labels(view))
            offset += max(100, scroll.bounds.height * 0.5)
        }
        for _ in 0..<3 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            settle()
            result.formUnion(labels(view))
        }
        // A lazy Form can revise row heights while scrolling down. Revisit the stabilized positions upward.
        let bottom = max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var reverseOffset = bottom
        while reverseOffset >= -scroll.adjustedContentInset.top {
            scroll.setContentOffset(CGPoint(x: 0, y: reverseOffset), animated: false)
            settle()
            result.formUnion(labels(view))
            reverseOffset -= max(80, scroll.bounds.height * 0.3)
        }
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        settle()
        result.formUnion(labels(view))
        return result
    }

    private func firstScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScroll).first
    }

    private func labels(_ view: UIView) -> [String] {
        var result: [String] = []
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel { result.append(label) }
            object.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(collect)
            if let view = object as? UIView { view.subviews.forEach(collect) }
        }
        collect(view)
        return result
    }

    private func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
}
