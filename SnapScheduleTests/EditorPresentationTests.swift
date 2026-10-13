import SwiftData
import SwiftUI
import UIKit
import XCTest
import Darwin
@testable import SnapSchedule

@MainActor
final class EditorPresentationTests: XCTestCase {
    func testAccessibilityHostDiagnostics() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let controller = UIHostingController(rootView: VStack { Text("AX probe"); Button("Probe action") {} })
        let window = try host(controller)
        defer { window.isHidden = true }
        settle(0.5)
        func visit(_ object: NSObject, depth: Int) {
            print("AXPROBE", depth, String(describing:type(of:object)), object.accessibilityLabel ?? "nil", object.accessibilityElementCount(), object.accessibilityElements?.count ?? -1, object.isAccessibilityElement)
            if let view = object as? UIView { view.subviews.forEach { visit($0,depth:depth+1) } }
        }
        visit(controller.view,depth:0)
        print("AXPROBE activated", controller.view.accessibilityElements as Any)
        XCTAssertTrue(accessibilityLabels(controller.view).contains("AX probe"))
    }

    func testOpeningLoadedOriginalRevalidatesPhotoAccess() throws {
        let data = try XCTUnwrap(fixtureImage(size: CGSize(width: 240, height: 320)).pngData())
        let attempts = EditorLoadAttempts()
        let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: "removed-after-preview") { _, _ in
            if attempts.next() == 1 { return ScreenshotImageInput(data: data, orientation: .up) }
            throw ScreenshotImageLoadError.inaccessible
        }
        model.load()
        settle(0.3)
        XCTAssertEqual(model.status, .ready)
        let controller = UIHostingController(rootView: ScreenshotPreviewView(model: model))
        let window = try host(controller)
        defer { window.isHidden = true }
        settle(0.5)
        XCTAssertEqual(model.status, .inaccessible, "Opening the original must not retain a stale ready image.")
        XCTAssertNil(model.image)
    }

    func testEditorsPreserveControlsAndExposeOriginalAtTheBottom() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let sourceID = "synthetic-original"
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(
            sourceAssetIdentifier: sourceID, sourceCandidateKey: "visual-review",
            evidenceText: "2026.10.05 · 18:30 · Seoul",
            title: String(localized: "Event"),
            date: CalendarDate(year: 2026, month: 10, day: 5),
            time: ClockTime(hour: 18, minute: 30), timeZoneIdentifier: "Asia/Seoul",
            reviewReasons: [.timeZoneInferred], notifyDayBefore: true
        )
        let schedule = Schedule(
            sourceCandidateID: UUID(), title: String(localized: "Event"),
            date: CalendarDate(year: 2026, month: 10, day: 5),
            time: ClockTime(hour: 18, minute: 30), timeZoneIdentifier: "Asia/Seoul",
            sourceAssetIdentifier: sourceID, notifyDayBefore: true,
            calendarExportStatus: .succeeded
        )
        container.mainContext.insert(candidate)
        container.mainContext.insert(schedule)
        try container.mainContext.save()

        for large in [false, true] {
            try review(
                CandidateDetailView(candidate: candidate).navigationTitle(String(localized: "Candidate")),
                container: container, name: "candidate", large: large,
                required: ["Register schedule", "Back", "Time zone (estimated)", "Notify one day before",
                           "Notify on the day", "Add to Calendar after registration"]
            )
            try review(
                ScheduleEditView(schedule: schedule), container: container, name: "schedule-edit", large: large,
                required: ["Save", "Cancel", "Include time", "Notify one day before", "Notify on the day"]
            )
            try review(
                ScheduleDetailView(schedule: schedule, notificationAuthorization: NotificationAuthorizationService(),
                                   notificationScheduler: NotificationScheduler())
                    .navigationTitle(String(localized: "Schedule")),
                container: container, name: "schedule-detail", large: large,
                required: ["Edit", "Delete Schedule", "Added to Calendar"]
            )
        }
        // Rendering must never alter the saved draft or register a candidate.
        XCTAssertEqual(candidate.reviewReasons, [.timeZoneInferred])
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(schedule.calendarExportStatus, .succeeded)
    }

    func testInlineOriginalFitsPortraitLandscapeAndSquareWithoutCropping() throws {
        for size in [CGSize(width: 180, height: 320), CGSize(width: 320, height: 180), CGSize(width: 240, height: 240)] {
            let image = fixtureImage(size: size)
            let data = try XCTUnwrap(image.pngData())
            let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: "synthetic") { _, _ in
                ScreenshotImageInput(data: data, orientation: .up)
            }
            let controller = UIHostingController(rootView: NavigationStack {
                Form { ScreenshotInlineSection(sourceScreenshotIdentifier: "synthetic") }
            }.environment(\.screenshotPreviewFactory, { _ in model }))
            let window = try host(controller)
            defer { window.isHidden = true }
            settle(0.6)
            XCTAssertEqual(model.status, .ready)
            let source = try XCTUnwrap(model.image)
            XCTAssertEqual(source.size.width / source.size.height, size.width / size.height, accuracy: 0.001)
            let labels = accessibilityLabels(controller.view)
            XCTAssertTrue(labels.contains(String(localized: "Original screenshot")))
            attach(controller.view, name: "original-\(Int(size.width))x\(Int(size.height))")
        }
    }

    private func review<V: View>(_ view: V, container: ModelContainer, name: String, large: Bool, required: [String]) throws {
        let controller = UIHostingController(rootView: NavigationStack {
            view.navigationBarTitleDisplayMode(.inline)
        }
            .modelContainer(container)
            .environment(\.screenshotPreviewFactory, { identifier in
                let data = self.fixtureImage(size: CGSize(width: 480, height: 640)).pngData()!
                return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in
                    ScreenshotImageInput(data: data, orientation: .up)
                }
            })
            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            .environment(\.colorScheme, large ? .dark : .light))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = try host(controller)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        settle(0.5)
        let scroll = try XCTUnwrap(firstScrollView(controller.view))
        var labels = Set<String>()
        let mode = large ? "large-dark" : "light"
        attach(controller.view, name: "\(name)-\(mode)-top")
        // Visit every viewport so Form's lazy rows and source loading are exercised.
        var offset: CGFloat = -scroll.adjustedContentInset.top
        while offset < scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            settle(0.12)
            labels.formUnion(accessibilityLabels(controller.view))
            offset += max(120, scroll.bounds.height * 0.6)
        }
        // Form estimates lazy row heights; decoding the source changes those estimates.
        // Resolve the end again after each layout so the image and expand button are visited.
        for _ in 0..<6 {
            let bottom = max(-scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            settle(0.25)
            labels.formUnion(accessibilityLabels(controller.view))
        }
        for key in required + ["Original screenshot"] {
            let value = String(localized: String.LocalizationValue(key))
            XCTAssertTrue(labels.contains { $0.contains(value) }, "\(name) missing \(value): \(labels.sorted())")
        }
        XCTAssertFalse(labels.contains(String(localized:"View Original Screenshot")), "Duplicate original button must stay removed")
        attach(controller.view, name: "\(name)-\(mode)-original")
        let original=try XCTUnwrap(PresentationAutomationScope.objects(in:controller.view).first {
            $0.isAccessibilityElement && $0.accessibilityLabel == String(localized:"Original screenshot")
                && $0.accessibilityTraits.contains(.button)
        },"The image itself must open the original")
        XCTAssertTrue(original.accessibilityActivate())
        settle(0.5)
        let preview=try XCTUnwrap(controller.presentedViewController)
        let previewLabels=accessibilityLabels(preview.view)
        XCTAssertTrue(previewLabels.contains(String(localized:"Close")))
        let zoom=try XCTUnwrap(firstScrollView(preview.view))
        XCTAssertEqual(zoom.maximumZoomScale,12)
        // Wait for the source image's fitted layout before zooming or capturing.
        // Otherwise a new sheet can report a zoom scale while its image frame is still empty.
        preview.view.layoutIfNeeded(); zoom.layoutIfNeeded(); settle(0.2)
        func views(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(views) }
        let imageView=try XCTUnwrap(views(zoom).compactMap {$0 as? UIImageView}.first)
        let decoded=try XCTUnwrap(imageView.image)
        XCTAssertEqual(decoded.size.width/decoded.size.height,0.75,accuracy:0.001)
        XCTAssertGreaterThan(imageView.bounds.width,0)
        let fittedWidth=imageView.frame.width
        attach(preview.view,name:"\(name)-\(mode)-original-open")
        zoom.setZoomScale(2,animated:false);zoom.layoutIfNeeded();settle(0.2)
        XCTAssertEqual(zoom.zoomScale,2,accuracy:0.01)
        XCTAssertGreaterThan(imageView.frame.width,fittedWidth*1.9)
        zoom.setZoomScale(1,animated:false);zoom.layoutIfNeeded();settle(0.1)
        preview.dismiss(animated:false);settle(0.2)
    }

    private func host<V: View>(_ controller: UIHostingController<V>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(Locale.current.identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func firstScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }

    private func accessibilityLabels(_ view: UIView) -> [String] {
        var labels: [String] = []
        func collect(_ object: NSObject) {
            if let label = object.accessibilityLabel { labels.append(label) }
            if let elements = object.accessibilityElements {
                elements.compactMap { $0 as? NSObject }.forEach(collect)
            }
        }
        func visit(_ view: UIView) {
            collect(view)
            view.subviews.forEach(visit)
        }
        visit(view)
        return labels
    }

    private func fixtureImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title = "SnapSchedule\nSYNTHETIC SOURCE"
            (title as NSString).draw(in: CGRect(x: 16, y: 20, width: size.width - 32, height: 100),
                                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 19), .foregroundColor: UIColor.darkGray])
            ("2026.10.05\n18:30 · Seoul" as NSString).draw(
                in: CGRect(x: 16, y: size.height / 2 - 20, width: size.width - 32, height: 60),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
            ("END OF ORIGINAL" as NSString).draw(
                at: CGPoint(x: 16, y: size.height - 35),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.darkGray])
        }
    }
}

private final class EditorLoadAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

// Test runtime only. SwiftUI lazily exposes its semantic tree to an automation client.
// Restore the Simulator flag; never enable VoiceOver or change user permissions.
@MainActor
final class PresentationAutomationScope {
    private let handle: UnsafeMutableRawPointer
    private let setEnabled: @convention(c) (Int32) -> Void
    private let previous: Int32

    init() throws {
        #if targetEnvironment(simulator)
        guard ["DC2BEFD2-98F0-477B-AB32-294F8E659FCA", "9713C13F-7AB6-47F8-883A-FBF7125B1B3F"].contains(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? ""),
              ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"),
              case .disabled = AdsConfiguration.current.state else {
            throw XCTSkip("Automation inspection requires the dedicated disabled Task42-1 Simulator")
        }
        handle = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let get = try XCTUnwrap(dlsym(handle, "_AXSAutomationEnabled"))
        let set = try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled"))
        let read = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)
        setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        previous = read()
        print("Task42-1 AX automation before=\(previous)")
        setEnabled(1)
        #else
        throw XCTSkip("Simulator automation inspection only")
        #endif
    }

    func restore() {
        setEnabled(previous)
        print("Task42-1 AX automation restored=\(previous)")
        dlclose(handle)
    }

    static func objects(in view: UIView) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            object.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(collect)
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { collect(element) }
                }
            }
            (object as? UIView)?.subviews.forEach(collect)
        }
        collect(view)
        return result
    }
}
