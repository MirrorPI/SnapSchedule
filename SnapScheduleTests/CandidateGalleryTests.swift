import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import SnapSchedule

@MainActor
final class CandidateGalleryTests: XCTestCase {
    func testSmallGalleryKeepsReadableSingleColumnAtAccessibilitySizes() {
        for count in [2, 3, 4] {
            XCTAssertEqual(CandidateGalleryLayout.columnCount(count: count, width: 375, accessibility: true), 1)
            XCTAssertEqual(CandidateGalleryLayout.columnCount(count: count, width: 375, accessibility: false), 2)
        }
    }

    // Catches a gallery accidentally rendering the old text rows or bulk controls.
    func testSingleCandidateDisplaysOriginalAndIndividualActions() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "fixture", sourceCandidateKey: "one",
                                          title: "Concert", date: CalendarDate(year: 2026, month: 10, day: 5))
        container.mainContext.insert(candidate)
        try container.mainContext.save()
        let data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let model = ScreenshotPreviewModel(sourceScreenshotIdentifier: "fixture") { _, _ in
            ScreenshotImageInput(data: data, orientation: .up)
        }
        let controller = UIHostingController(rootView: NavigationStack {
            CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in })
        }.modelContainer(container).environment(\.screenshotThumbnailFactory, { _ in model }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        let labels = labels(in: controller.view)
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Original screenshot")) }, "Original is missing: \(labels)")
        XCTAssertFalse(labels.contains(String(localized: "Select All")))
        XCTAssertFalse(labels.contains(String(localized: "Deselect All")))
        XCTAssertTrue(labels.contains { $0.contains(String(localized: "Ignore actions for \("Concert")")) })
    }

    // Historical case name retained. The approved UI has one registration action and saves on exit.
    func testEditorOffersIndividualRegistrationWithoutRemovingSaveOrCancel() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        let container = try SnapScheduleModelContainer.makeInMemory()
        let candidate = ScheduleCandidate(sourceAssetIdentifier: "fixture", sourceCandidateKey: "edit",
                                          title: "Concert", date: CalendarDate(year: 2026, month: 10, day: 5))
        container.mainContext.insert(candidate)
        try container.mainContext.save()
        let navigation = AppTabNavigation(); navigation.tab = .candidates; navigation.candidateDetailID = candidate.id
        let controller = UIHostingController(rootView: NavigationStack {
            CandidateDetailView(candidate: candidate, navigation: navigation)
        }.modelContainer(container).environment(\.screenshotPreviewFactory, { identifier in
            let data = self.fixtureImage(size: CGSize(width: 320, height: 560), index: 0).pngData()!
            return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in
                ScreenshotImageInput(data: data, orientation: .up)
            }
        }).environment(\.dynamicTypeSize, .large).environment(\.colorScheme, .light))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        var allLabels = labels(in: controller.view)
        var registrationCounts:[Int]=[]
        func scrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView).first
        }
        let scroll = try XCTUnwrap(scrollView(controller.view))
        for step in 0..<12 {
            scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 250), animated: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            allLabels += labels(in: controller.view)
            registrationCounts.append(PresentationAutomationScope.objects(in:controller.view).filter {
                $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button)
                    && $0.accessibilityLabel == String(localized:"Register schedule")
            }.count)
            if [2, 3, 4].contains(step) { attach(controller.view, name: "individual-editor-step-\(step)") }
        }
        XCTAssertTrue(allLabels.contains(String(localized: "Register schedule")), "Missing unified registration: \(allLabels)")
        XCTAssertEqual(registrationCounts.max(),1,"A second registration control in any lazy viewport must fail")
        XCTAssertTrue(allLabels.contains(String(localized: "Back")))
        XCTAssertFalse(allLabels.contains(String(localized: "Save")))
        XCTAssertFalse(allLabels.contains(String(localized: "Cancel")))
        let top = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x:0,y:top), animated:false); settle(0.3)
        let actions = PresentationAutomationScope.objects(in: controller.view).filter {
            let key=NSSelectorFromString("accessibilityIdentifier")
            return $0.responds(to:key) && ($0.perform(key)?.takeUnretainedValue() as? String) == "candidate-register"
                && $0.accessibilityTraits.contains(.button)
        }
        XCTAssertEqual(actions.count,1,"Only one registration control is allowed")
        func views(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(views) }
        let field=try XCTUnwrap(views(controller.view).compactMap { $0 as? UITextView }.first)
        field.text="Edited pending title";field.delegate?.textViewDidChange?(field)
        navigation.tab = .settings
        XCTAssertEqual(candidate.title,"Edited pending title","Leaving must save the draft")
        XCTAssertEqual(navigation.tab,.settings)
        XCTAssertEqual(candidate.sourceAssetIdentifier,"fixture")
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    // A changed date or removal must not reorder surviving cards; new arrivals append.
    func testGalleryOrderCompactsWithoutMovingSurvivorsAndKeepsSharedPhotoCandidatesSeparate() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext
        let first = makeCandidate(0), second = makeCandidate(1), third = makeCandidate(2)
        [first, second, third].forEach { context.insert($0) }
        try context.save()
        let order = [first.id, second.id, third.id]
        second.date = CalendarDate(year: 2026, month: 9, day: 1)
        let incoming = makeCandidate(3)
        incoming.date = CalendarDate(year: 2026, month: 8, day: 1)
        context.insert(incoming)
        try context.save()
        XCTAssertEqual(CandidateListPresentation.orderedPending([incoming, third, second, first], scans: [], preserving: order).map(\.id),
                       [first.id, second.id, third.id, incoming.id])
        // First and second intentionally share a source photo. Registering first must keep second.
        _ = try ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}) .register(candidateIDs: [first.id])
        XCTAssertEqual(CandidateListPresentation.orderedPending([incoming, third, second, first], scans: [], preserving: order).map(\.id),
                       [second.id, third.id, incoming.id])
        try CandidateDismissalService(context: context).dismiss(candidateIDs: [third.id])
        XCTAssertEqual(CandidateListPresentation.orderedPending([incoming, third, second, first], scans: [], preserving: order).map(\.id),
                       [second.id, incoming.id])
        XCTAssertEqual(second.reviewStatus, .pending)
        XCTAssertEqual(second.sourceAssetIdentifier, first.sourceAssetIdentifier)
    }

    func testCountLayoutsAndSeparateIgnoreHitArea() {
        for (count, expected) in [(0, 1), (1, 1), (2, 2), (3, 2), (4, 2), (5, 3), (7, 3)] {
            XCTAssertEqual(CandidateGalleryLayout.columnCount(count: count, width: 375, accessibility: false), expected)
        }
        XCTAssertEqual(CandidateGalleryLayout.columnCount(count: 7, width: 320, accessibility: false), 2)
        XCTAssertEqual(CandidateGalleryLayout.columnCount(count: 7, width: 375, accessibility: true), 1)
        XCTAssertEqual(CandidateGalleryLayout.imageHeight(count: 3, columns: 2, viewportHeight: 600),
                       CandidateGalleryLayout.imageHeight(count: 4, columns: 2, viewportHeight: 600))
        let path = CandidateGalleryOpenShape().path(in: CGRect(x: 0, y: 0, width: 120, height: 200))
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 20), eoFill: true))
        XCTAssertFalse(path.contains(CGPoint(x: 110, y: 10), eoFill: true))
        XCTAssertFalse(path.contains(CGPoint(x: 80, y: 40), eoFill: true))
        XCTAssertTrue(path.contains(CGPoint(x: 80, y: 50), eoFill: true))
    }

    func testActualGalleryRendersCountsShapesLargeTextAndDarkMode() throws {
        let automation = try PresentationAutomationScope(); defer { automation.restore() }
        for count in [0, 1, 2, 3, 4, 5, 7] {
            for large in [false, true] {
                let container = try SnapScheduleModelContainer.makeInMemory()
                let candidates = (0..<count).map(makeCandidate)
                candidates.forEach { container.mainContext.insert($0) }
                try container.mainContext.save()
                let controller = UIHostingController(rootView: NavigationStack {
                    CandidateListView(selectionState: CandidateSelectionState(), onOpenCandidate: { _ in })
                }.modelContainer(container)
                    .environment(\.screenshotThumbnailFactory, { identifier in
                        let index = Int(identifier.split(separator: "-").last ?? "0") ?? 0
                        let sizes = [CGSize(width: 320, height: 560), CGSize(width: 560, height: 320), CGSize(width: 400, height: 400)]
                        let data = self.fixtureImage(size: sizes[index % 3], index: index).pngData()!
                        return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { _, _ in
                            ScreenshotImageInput(data: data, orientation: .up)
                        }
                    })
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                    .environment(\.colorScheme, large ? .dark : .light))
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene)
                window.frame = UIScreen.main.bounds
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true; previous?.makeKeyAndVisible() }
                settle(0.6)
                attach(controller.view, name: "gallery-\(count)-\(large ? "large-dark" : "light")-top")
                var initial = labels(in: controller.view)
                if count > 0, !initial.contains(where: { $0.contains(String(localized: "Original screenshot")) }), let scroll = scrollView(in: controller.view) {
                    for step in 0..<25 {
                        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 140), animated: false)
                        settle(0.12); initial += labels(in: controller.view)
                        if initial.contains(where: { $0.contains(String(localized: "Original screenshot")) }) { break }
                    }
                }
                XCTAssertFalse(initial.contains(String(localized: "Select All")))
                XCTAssertFalse(initial.contains(String(localized: "Deselect All")))
                if count == 0 {
                    XCTAssertTrue(initial.contains { $0.contains(String(localized: "No candidates to review")) })
                } else {
                    XCTAssertTrue(initial.contains { $0.contains(String(localized: "Original screenshot")) })
                    let images = elements(in: controller.view).filter { $0.identifier?.hasPrefix("candidate-image-") == true }
                    let ignores = elements(in: controller.view).filter { $0.identifier?.hasPrefix("candidate-ignore-") == true }
                    XCTAssertFalse(images.isEmpty)
                    XCTAssertFalse(ignores.isEmpty)
                    // AX coordinate transforms can round an exact 44pt frame to 43.99999999999997.
                    for element in ignores {
                        XCTAssertGreaterThanOrEqual(element.frame.width + 0.001, 44)
                        XCTAssertGreaterThanOrEqual(element.frame.height + 0.001, 44)
                    }
                    var seen = Set(initial)
                    if let scroll = scrollView(in: controller.view) {
                        var y: CGFloat = 0
                        while y <= scroll.contentSize.height {
                            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                            settle(0.12)
                            seen.formUnion(labels(in: controller.view))
                            y += max(160, scroll.bounds.height * 0.65)
                        }
                        attach(controller.view, name: "gallery-\(count)-\(large ? "large-dark" : "light")-bottom")
                    }
                    for candidate in candidates {
                        XCTAssertTrue(seen.contains { $0.contains(CandidateText.displayTitle(candidate)) }, "Missing card \(candidate.title)")
                    }
                }
                XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Schedule>()), 0)
                XCTAssertTrue(candidates.allSatisfy { $0.reviewStatus == .pending })
            }
        }
    }

    // Exercises the same draft-to-registration boundary used by the editor button.
    func testIndividualRegistrationSavesEditsAndOptionsAndLeavesOtherPhotoCandidatePending() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext
        let first = makeCandidate(0), other = makeCandidate(1)
        [first, other].forEach { context.insert($0) }
        try context.save()
        var draft = CandidateDetailDraft(candidate: first)
        draft.title = "Edited concert"
        draft.date = CalendarDate(year: 2026, month: 11, day: 12)
        draft.notifyDayBefore = true
        draft.notifySameDay = true
        draft.calendarExportRequested = true
        var widgetRefreshes = 0
        let service = ScheduleRegistrationService(context: context, widgetSnapshotRefresh: { widgetRefreshes += 1 })
        let result = try draft.register(to: first, in: context, service: service)
        XCTAssertEqual(result.scheduleIDs.count, 1)
        let schedule = try XCTUnwrap(try context.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.sourceCandidateID, first.id)
        XCTAssertEqual(schedule.title, "Edited concert")
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 11, day: 12))
        XCTAssertTrue(schedule.notifyDayBefore)
        XCTAssertTrue(schedule.notifySameDay)
        XCTAssertEqual(schedule.calendarExportStatus, .pending)
        XCTAssertEqual(widgetRefreshes, 1)
        XCTAssertEqual(other.reviewStatus, .pending)
        XCTAssertEqual(other.title, "Application")
        XCTAssertEqual(other.sourceAssetIdentifier, first.sourceAssetIdentifier)
        XCTAssertThrowsError(try draft.register(to: first, in: context, service: service))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testIndividualRegistrationFailureKeepsSavedReviewAndCanRetryWithoutDuplicating() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext
        context.autosaveEnabled = false
        let candidate = makeCandidate(0)
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = "Reviewed title"
        let failing = ScheduleRegistrationService(context: context,
            save: { _ in throw NSError(domain: "SaveFailure", code: 1) }, widgetSnapshotRefresh: {})
        XCTAssertThrowsError(try draft.register(to: candidate, in: context, service: failing)) {
            XCTAssertEqual($0 as? ScheduleRegistrationError, .saveFailed)
        }
        XCTAssertEqual(candidate.reviewStatus, .pending)
        XCTAssertNil(candidate.registeredScheduleID)
        XCTAssertEqual(candidate.title, "Reviewed title")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
        let result = try draft.register(to: candidate, in: context,
                                       service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
        XCTAssertEqual(result.scheduleIDs.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    func testIncompleteOrStaleIndividualReviewCannotSaveOrRegister() throws {
        let container = try SnapScheduleModelContainer.makeInMemory()
        let context = container.mainContext
        let candidate = makeCandidate(1)
        context.insert(candidate)
        try context.save()
        var draft = CandidateDetailDraft(candidate: candidate)
        draft.title = "Unsaved title"
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
        XCTAssertEqual(candidate.title, "Application")
        draft.confirmedReviewReasons.insert(.relativeDate)
        try CandidateDismissalService(context: context).dismiss(candidateIDs: [candidate.id])
        XCTAssertThrowsError(try draft.register(to: candidate, in: context))
        XCTAssertEqual(candidate.title, "Application")
        XCTAssertEqual(candidate.reviewStatus, .dismissed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 0)
    }

    func testIndividualRemovalPersistsAndReopenKeepsSharedPhotoSurvivor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gallery.store")
        let survivorID = try autoreleasepool {
            let context = ModelContext(try SnapScheduleModelContainer.make(url: url))
            context.autosaveEnabled = false
            let first = makeCandidate(0), survivor = makeCandidate(1), ignored = makeCandidate(2)
            [first, survivor, ignored].forEach { context.insert($0) }
            try context.save()
            var draft = CandidateDetailDraft(candidate: first)
            _ = try draft.register(to: first, in: context,
                                   service: ScheduleRegistrationService(context: context, widgetSnapshotRefresh: {}))
            try CandidateDismissalService(context: context).dismiss(candidateIDs: [ignored.id])
            return survivor.id
        }
        let context = ModelContext(try SnapScheduleModelContainer.make(url: url))
        let stored = try context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(CandidateListPresentation.sortedPending(stored, scans: []).map(\.id), [survivorID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Schedule>()), 1)
    }

    private func makeCandidate(_ index: Int) -> ScheduleCandidate {
        ScheduleCandidate(sourceAssetIdentifier: "source-\(index == 1 ? 0 : index)", sourceCandidateKey: "candidate-\(index)",
                          title: ["Concert", "Application", "Gift voucher", "Conference", "Reservation", "Ticket booking", "Event"][index % 7],
                          date: CalendarDate(year: 2026, month: 10, day: 5 + index),
                          reviewReasons: index == 1 ? [.relativeDate] : [])
    }

    private func fixtureImage(size: CGSize, index: Int) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.darkGray]
            ("SYNTHETIC SCREENSHOT" as NSString).draw(in: CGRect(x: 16, y: 16, width: size.width - 32, height: 80), withAttributes: attributes)
            ("EVENT \(index + 1)\n2026.10.\(5 + index)" as NSString).draw(in: CGRect(x: 16, y: size.height / 2, width: size.width - 32, height: 80), withAttributes: attributes)
            ("END OF ORIGINAL" as NSString).draw(at: CGPoint(x: 16, y: size.height - 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    private func attach(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "\(name)-\(Locale.current.identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func elements(in view: UIView) -> [(identifier: String?, frame: CGRect)] {
        var result: [(String?, CGRect)] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ item: NSObject) {
            guard visited.insert(ObjectIdentifier(item)).inserted else { return }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let identifier = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
            if identifier != nil {
                result.append((identifier, item.accessibilityFrame))
            }
            item.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(visit)
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for i in 0..<count { if let child = item.accessibilityElement(at: i) as? NSObject { visit(child) } }
            }
            (item as? UIView)?.subviews.forEach(visit)
        }
        visit(view)
        return result
    }

    private func labels(in view: UIView) -> [String] {
        PresentationAutomationScope.objects(in: view).compactMap(\.accessibilityLabel)
    }
}
