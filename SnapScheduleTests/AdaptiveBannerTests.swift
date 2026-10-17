import XCTest
import GoogleMobileAds
import UIKit
@testable import SnapSchedule

@MainActor
final class AdaptiveBannerTests: XCTestCase {
    func testCompactHeightChangesReplacePlacementAndRejectOversizedCreative() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 343, eligible: true, maximumHeight: 50)
        let compact = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.adView(compact, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 343, height: 75)))
        XCTAssertNil(fixture.controller.banner)
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.controller.update(width: 343, eligible: true, maximumHeight: 100)
        let portrait = try XCTUnwrap(fixture.controller.banner)
        XCTAssertEqual(fixture.requests.count, 2)
        fixture.controller.bannerViewDidReceiveAd(compact)
        fixture.controller.adView(compact, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 343, height: 50)))
        XCTAssertEqual(fixture.controller.height, 0)
        XCTAssertTrue(fixture.controller.banner === portrait)
        for height in [CGFloat.zero, 49, 101, .nan, .infinity] {
            fixture.controller.update(width: 343, eligible: true, maximumHeight: height)
        }
        XCTAssertNil(fixture.controller.banner)
        XCTAssertEqual(fixture.requests.count, 2)
    }
    // Removing the consent gate must send an unauthorized request and fail this test.
    func testDeniedConsentAndInvalidWidthNeverLoad() {
        let fixture = BannerFixture(allowed: false)
        fixture.controller.update(width: 320, eligible: true)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertNil(fixture.controller.banner)
        fixture.allowed = true
        fixture.manager.activate()
        for width in [CGFloat.zero, -1, .nan, .infinity, 200] {
            fixture.controller.update(width: width, eligible: true)
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testRepeatedUpdatesLoadOnceWithTestIDAndNPAOnly() throws {
        let fixture = BannerFixture()
        for _ in 0..<5 { fixture.controller.update(width: 320.8, eligible: true) }
        XCTAssertEqual(fixture.requests.count, 1)
        let banner = try XCTUnwrap(fixture.controller.banner)
        XCTAssertEqual(banner.adUnitID, "ca-app-pub-3940256099942544/2435281174")
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual((request.adNetworkExtras(for: Extras.self) as? Extras)?.additionalParameters?["npa"] as? String, "1")
        XCTAssertNil(request.contentURL)
        XCTAssertNil(request.keywords)
        XCTAssertEqual(fixture.controller.height, 0)
    }

    func testRevisionDisposesLoadedBannerAndRejectsOldSuccessSizeAndFailure() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let old = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.adView(old, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 320, height: 50)))
        fixture.controller.bannerViewDidReceiveAd(old)
        XCTAssertEqual(fixture.controller.height, 50)
        fixture.manager.presentPrivacyOptions()
        fixture.controller.update(width: 320, eligible: true)
        XCTAssertNil(fixture.controller.banner)
        XCTAssertNil(old.delegate)
        XCTAssertNil(old.adSizeDelegate)
        XCTAssertEqual(fixture.controller.height, 0)
        fixture.optionsCompletion?(nil)
        fixture.controller.update(width: 320, eligible: true)
        let current = try XCTUnwrap(fixture.controller.banner)
        XCTAssertFalse(current === old)
        fixture.controller.bannerViewDidReceiveAd(old)
        fixture.controller.adView(old, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 320, height: 100)))
        fixture.controller.bannerView(old, didFailToReceiveAdWithError: NSError(domain: "late", code: 1))
        XCTAssertTrue(fixture.controller.banner === current)
        XCTAssertEqual(fixture.controller.height, 0)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testLivePermissionIsRecheckedEvenBeforeSwiftUIUpdate() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let old = try XCTUnwrap(fixture.controller.banner)
        fixture.allowed = false
        fixture.controller.bannerViewDidReceiveAd(old)
        XCTAssertNil(fixture.controller.banner)
        XCTAssertEqual(fixture.controller.height, 0)
    }

    func testFailureCollapsesAndDoesNotRetryOnBodyUpdates() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let old = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.bannerView(old, didFailToReceiveAdWithError: NSError(domain: "offline-no-fill", code: 1))
        for _ in 0..<5 { fixture.controller.update(width: 320, eligible: true) }
        XCTAssertNil(fixture.controller.banner)
        XCTAssertEqual(fixture.controller.height, 0)
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.controller.bannerViewDidReceiveAd(old)
        XCTAssertEqual(fixture.controller.height, 0)
    }

    func testWidthAndVisibilityChangesReplaceAndDisposeBanner() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let old = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.update(width: 700, eligible: true)
        XCTAssertNil(old.delegate)
        XCTAssertEqual(fixture.requests.count, 2)
        fixture.controller.update(width: 700, eligible: false)
        XCTAssertNil(fixture.controller.banner)
        fixture.controller.update(width: 700, eligible: false)
        XCTAssertEqual(fixture.requests.count, 2)
        fixture.controller.update(width: 700, eligible: true)
        XCTAssertEqual(fixture.requests.count, 3)
        fixture.controller.stop()
        XCTAssertNil(fixture.controller.banner)
        XCTAssertEqual(fixture.controller.height, 0)
    }

    func testReceiveBeforeSizeWaitsForValidSizeInsteadOfLosingBanner() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let banner = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.bannerViewDidReceiveAd(banner)
        XCTAssertTrue(fixture.controller.banner === banner)
        XCTAssertEqual(fixture.controller.height, 0)
        fixture.controller.adView(banner, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 320, height: 50)))
        XCTAssertEqual(fixture.controller.height, 50)
    }

    func testInvalidCreativeSizeNeverOverlapsContent() throws {
        let fixture = BannerFixture()
        fixture.controller.update(width: 320, eligible: true)
        let banner = try XCTUnwrap(fixture.controller.banner)
        fixture.controller.adView(banner, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: 400, height: 250)))
        fixture.controller.bannerViewDidReceiveAd(banner)
        XCTAssertEqual(fixture.controller.height, 0)
        XCTAssertNil(fixture.controller.banner)
    }
}

@MainActor
private final class BannerFixture {
    var allowed: Bool
    var requests: [Request] = []
    var optionsCompletion: AdsConsentSDK.Completion?
    // All loads/SDK calls are intercepted; fixture IDs are independent of the app build.
    private let configuration = AdsConfiguration.resolve(environment: .debug,
        appID: "ca-app-pub-3940256099942544~1458002511", bannerID: "ca-app-pub-3940256099942544/2435281174")
    lazy var manager = AdsConsentManager(configuration: configuration, sdk: .init(
        snapshot: { .init(canRequestAds: self.allowed, formRequired: false, privacyOptionsRequired: true) },
        update: { $0(nil) }, loadForm: { _ in },
        privacyOptions: { self.optionsCompletion = $0 }, start: { $0() }), tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
    lazy var controller = AdaptiveBannerController(manager: manager, configuration: configuration, load: { [weak self] _, request in
        self?.requests.append(request) // Intercept the external network boundary only.
    })
    init(allowed: Bool = true) { self.allowed = allowed; manager.activate() }
}

@MainActor
final class AdaptiveBannerIntegrationTests: XCTestCase {
    // The old test-only placement gate stranded the App Store build with no requests.
    // Intercept load so this regression test never sends a production ad request.
    func testProductionConfigurationLoadsOnceAfterConsentWithNPA() throws {
        let fixture = BannerFixture()
        var requests: [Request] = []
        let configuration = AdsConfiguration.resolve(environment: .production,
            appID: "ca-app-pub-1234567890123456~1234567890", bannerID: "ca-app-pub-1234567890123456/0987654321")
        let controller = AdaptiveBannerController(manager: fixture.manager, configuration: configuration,
            load: { _, request in requests.append(request) })
        for _ in 0..<5 { controller.update(width: 390, eligible: true) }
        let banner = try XCTUnwrap(controller.banner)
        XCTAssertEqual(banner.adUnitID, "ca-app-pub-1234567890123456/0987654321")
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual((request.adNetworkExtras(for: Extras.self) as? Extras)?.additionalParameters?["npa"] as? String, "1")
        XCTAssertNil(request.contentURL)
        XCTAssertNil(request.keywords)

        fixture.allowed = false
        controller.update(width: 390, eligible: true)
        XCTAssertNil(controller.banner)
        XCTAssertEqual(requests.count, 1)
    }

    func testProductionConfigurationDoesNotLoadBeforeConsent() {
        let fixture = BannerFixture(allowed: false)
        let configuration = AdsConfiguration.resolve(environment: .production,
            appID: "ca-app-pub-1234567890123456~1234567890", bannerID: "ca-app-pub-1234567890123456/0987654321")
        let controller = AdaptiveBannerController(manager: fixture.manager, configuration: configuration,
            load: { _, _ in XCTFail("Consent must still gate production requests") })
        controller.update(width: 390, eligible: true)
        XCTAssertNil(controller.banner)
    }

    func testActualUMPAllowsOfficialTestAdOrRecordsUnverified() async throws {
        XCTAssertTrue(AdsConfiguration.buildEnvironment == .debug || AdsConfiguration.buildEnvironment == .qa)
        let manager = AdsConsentManager.shared
        manager.activate()
        for _ in 0..<150 {
            if manager.canRequestAds || manager.state == .unavailable { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard manager.canRequestAds else {
            throw XCTSkip("Actual UMP did not permit ads; state=\(manager.state), busy=\(manager.isBusy), revision=\(manager.revision), error=\(manager.errorMessage ?? "none"). No reset/geography/consent bypass; Test Ad remains unverified.")
        }
        let display = BannerDisplayProbe()
        let controller = AdaptiveBannerController(manager: manager, load: { banner, request in
            display.target = banner.delegate
            banner.delegate = display
            banner.load(request)
        })
        let host = UIHostingController(rootView: BannerLayoutFixture(manager: manager, controller: controller))
        let window = try makeWindow(host)
        defer { controller.stop(); window.isHidden = true }
        for _ in 0..<150 {
            if controller.height > 0 && display.impressions > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard manager.canRequestAds else { throw XCTSkip("UMP permission changed while waiting; Test Ad unverified.") }
        XCTAssertGreaterThan(controller.height, 0, "No Test Ad loaded within 30 seconds.")
        XCTAssertGreaterThan(display.impressions, 0, "Loaded is not displayed: SDK must record a visible impression.")
        if let banner = controller.banner {
            print("Task41 actual banner frame=\(banner.frame) hidden=\(banner.isHidden) window=\(banner.window != nil) parent=\(String(describing: banner.superview?.bounds))")
            for view in descendants(banner) {
                print("Task41 ad view \(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alpha)")
            }
        }
        // Receipt/impression precede WebKit painting; verify actual pixels separately.
        var painted = false
        for _ in 0..<50 {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let words = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            if words.joined(separator: " ").localizedCaseInsensitiveContains("Test mode") {
                print("[Task41 actual pixels] \(words)")
                painted = true
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        attach(host.view, name: painted ? "actual-official-Test-Ad-painted" : "actual-Test-Ad-white")
        XCTAssertTrue(painted, "SDK success must also paint official Test mode pixels.")
    }

    func testBannerHeightUsesSafeViewportOnSmallAndLargePhones() {
        let small=AdaptiveBannerLayout(size:CGSize(width:375,height:598))
        let large=AdaptiveBannerLayout(size:CGSize(width:428,height:790))
        let landscape=AdaptiveBannerLayout(size:CGSize(width:667,height:320))
        XCTAssertGreaterThanOrEqual(small.height,50)
        XCTAssertLessThanOrEqual(small.height,60)
        XCTAssertGreaterThan(large.height,small.height)
        XCTAssertLessThanOrEqual(large.height,100)
        XCTAssertEqual(landscape.height,50)
        XCTAssertEqual(small.width,343)
        let inset = AdaptiveBannerLayout(size:CGSize(width:428,height:900),safeAreaInsets:EdgeInsets(top:60,leading:0,bottom:40,trailing:0))
        XCTAssertEqual(inset.height,80)
    }

    func testFixedLayoutSafeWidthAndResize() async throws {
        let fixture = BannerFixture()
        let controller = fixture.controller
        let content = BannerLayoutFixture(manager: fixture.manager, controller: controller)
        let host = UIHostingController(rootView: content)
        let window = try makeWindow(host)
        defer { controller.stop(); window.isHidden = true }
        for (name, size, dark, large) in [
            ("small-portrait", CGSize(width: 375, height: 667), false, false),
            ("landscape", CGSize(width: 667, height: 375), false, false),
            ("large-dark", CGSize(width: 375, height: 667), true, true)
        ] {
            host.rootView = BannerLayoutFixture(manager: fixture.manager, controller: controller, large: large)
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let banner = try XCTUnwrap(controller.banner)
            let width = banner.adSize.size.width
            XCTAssertGreaterThanOrEqual(width, 320)
            XCTAssertLessThanOrEqual(width, size.width - 32)
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: width, height: 50))
            label.text = "Synthetic layout fixture — not an ad"
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 12)
            label.backgroundColor = .systemYellow
            banner.addSubview(label)
            controller.adView(banner, willChangeAdSizeTo: adSizeFor(cgSize: CGSize(width: width, height: 50)))
            controller.bannerViewDidReceiveAd(banner)
            // This fixture has no SDK creative; supply its intrinsic size for UIKit layout only.
            banner.bounds.size = CGSize(width: width, height: 50)
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let frame = banner.convert(banner.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertEqual(controller.height, 50)
            attach(host.view, name: "synthetic-banner-\(name)")
        }
        let banner = try XCTUnwrap(controller.banner)
        let list = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        let before = banner.convert(banner.bounds, to: host.view).minY
        list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 40), animated: false)
        host.view.layoutIfNeeded()
        let after = banner.convert(banner.bounds, to: host.view).minY
        XCTAssertEqual(before, after, accuracy: 1, "Banner must remain outside body scrolling.")
        let loadedContentHeight = list.contentSize.height
        controller.bannerView(banner, didFailToReceiveAdWithError: NSError(domain: "no-fill", code: 1))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.height, 0)
        XCTAssertNil(banner.superview)
        list.layoutIfNeeded()
        XCTAssertEqual(list.contentSize.height, loadedContentHeight, accuracy: 1,
            "Failure cannot change the reserved slot or body geometry.")
        attach(host.view, name: "synthetic-banner-failure-empty-slot")
    }

    func testSheetKeyboardDisposesAndReturnLoadsOnlyOnce() async throws {
        let fixture = BannerFixture()
        let presentation = BannerPresentationState()
        let host = UIHostingController(rootView: BannerLayoutFixture(manager: fixture.manager,
            controller: fixture.controller, presentation: presentation))
        let window = try makeWindow(host)
        defer { fixture.controller.stop(); window.isHidden = true }
        for _ in 0..<30 {
            if fixture.controller.banner != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let old = try XCTUnwrap(fixture.controller.banner)
        presentation.showingSheet = true
        for _ in 0..<30 {
            if fixture.controller.banner == nil && host.presentedViewController != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(fixture.controller.banner)
        XCTAssertNil(old.delegate)
        XCTAssertEqual(fixture.requests.count, 1)
        let sheet = try XCTUnwrap(host.presentedViewController)
        for _ in 0..<30 {
            if descendants(sheet.view).contains(where: { ($0 as? UITextField)?.isFirstResponder == true }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(descendants(sheet.view).contains { ($0 as? UITextField)?.isFirstResponder == true })
        attach(sheet.view, name: "synthetic-settings-sheet-keyboard-no-banner")
        presentation.showingSheet = false
        for _ in 0..<30 {
            if fixture.controller.banner != nil && host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let current = try XCTUnwrap(fixture.controller.banner)
        XCTAssertFalse(current === old)
        XCTAssertEqual(fixture.requests.count, 2)
        fixture.controller.bannerViewDidReceiveAd(old)
        XCTAssertEqual(fixture.controller.height, 0)
    }

    private func makeWindow<V: View>(_ host: UIHostingController<V>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return window
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import SwiftUI

private struct BannerLayoutFixture: View {
    let manager: AdsConsentManager
    let controller: AdaptiveBannerController
    var large = false
    var presentation = BannerPresentationState()
    @State private var selected = CalendarDate.gregorianDate(from: .now)
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = AdaptiveBannerLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
                VStack(spacing: 0) {
                    AdaptiveBannerView(controller: controller, reservedHeight: layout.height)
                        .frame(width: layout.width).frame(maxWidth: .infinity)
                    List {
                        Section("Candidate review") { Button("Review candidates") {} }
                        Section("Calendar") {
                            HomeCalendarView(originals: [], selectedDate: $selected, timeZone: .current)
                                .frame(minHeight: 330).listRowInsets(EdgeInsets())
                        }
                        ForEach(0..<8) { value in Text("Schedule fixture \(value)") }
                    }.listStyle(.plain)
                }
                .modifier(AdaptiveBannerLifecycle(manager: manager, controller: controller,
                    eligible: !presentation.showingSheet, layout: layout))
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Match Home's navigation chrome so list scrolling cannot collapse
            // a fixture-only large title and move the entire content container.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Settings") { presentation.showingSheet = true } }
        }
        .sheet(isPresented: Binding(get: { presentation.showingSheet }, set: { presentation.showingSheet = $0 })) {
            BannerKeyboardFixture()
        }
        .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
    }
}

@MainActor
private final class BannerDisplayProbe: NSObject, BannerViewDelegate {
    weak var target: BannerViewDelegate?
    var impressions = 0
    func bannerViewDidReceiveAd(_ bannerView: BannerView) { target?.bannerViewDidReceiveAd?(bannerView) }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        target?.bannerView?(bannerView, didFailToReceiveAdWithError: error)
    }
    func bannerViewDidRecordImpression(_ bannerView: BannerView) { impressions += 1 }
}

@MainActor @Observable
private final class BannerPresentationState { var showingSheet = false }

private struct BannerKeyboardFixture: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        Form { TextField("Synthetic keyboard fixture", text: $text).focused($focused) }
            .task { focused = true }
    }
}

import WebKit
import Vision

@MainActor
final class BannerRenderingDiagnosticTests: XCTestCase {
    func testNativeBannerAndLocalWebKitComparison() async throws {
        guard AdsConfiguration.buildEnvironment == .debug,
              case let .configured(ids) = AdsConfiguration.current.state,
              ids.bannerID == "ca-app-pub-3940256099942544/2435281174" else {
            throw XCTSkip("Official Debug test IDs only")
        }
        let manager = AdsConsentManager.shared
        manager.activate()
        for _ in 0..<150 {
            if manager.canRequestAds || manager.state == .unavailable { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard manager.canRequestAds else { throw XCTSkip("Real UMP does not permit requests. No override.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        let inline = BannerView(adSize: inlineAdaptiveBanner(width: 320, maxHeight: 100))
        let fixed = BannerView(adSize: AdSizeLargeBanner)
        let probe = NativeBannerProbe()
        let delayed = AdaptiveBannerController(manager: manager)
        let web = WKWebView(frame: CGRect(x: 16, y: 420, width: 320, height: 100))
        defer {
            for banner in [inline, fixed] { banner.delegate = nil; banner.removeFromSuperview() }
            delayed.stop()
            web.stopLoading()
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        for (index, banner) in [inline, fixed].enumerated() {
            banner.frame = CGRect(x: 16, y: 130 + index * 140, width: 320, height: 100)
            banner.rootViewController = host
            banner.adUnitID = ids.bannerID
            banner.delegate = probe
            host.view.addSubview(banner)
            banner.load(try XCTUnwrap(manager.makeRequest()))
        }
        delayed.update(width: 320, eligible: true)
        host.view.addSubview(web)
        web.loadHTMLString("<html><meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0;background:#0044aa;color:white;font:26px sans-serif'>LOCAL WEBKIT CHECK</body></html>", baseURL: nil)
        for _ in 0..<150 {
            if probe.received == 2 && !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        for _ in 0..<150 {
            if delayed.height > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        if let banner = delayed.banner {
            banner.rootViewController = host
            banner.frame = CGRect(x: 16, y: 550, width: 320, height: delayed.height)
            host.view.addSubview(banner)
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(probe.received, 2, "Native SDK requests must finish for comparison to be valid.")
        let full = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        save(full, name: "Task41-native-inline-fixed-local-web")
        let fullWords = try recognize(full)
        print("[Task41 rendering] OS=\(UIDevice.current.systemVersion) nativeReceived=\(probe.received) impressions=\(probe.impressions) errors=\(probe.errors) fullOCR=\(fullWords)")
        let webImage = try await web.takeSnapshot(configuration: nil)
        save(webImage, name: "Task41-local-webkit-snapshot")
        let webWords = try recognize(webImage)
        print("[Task41 rendering] localWebSnapshotOCR=\(webWords)")
        XCTAssertTrue(webWords.joined(separator: " ").contains("LOCAL WEBKIT"), "Control WebKit renderer must paint local HTML.")
    }
    private func recognize(_ image: UIImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
    private func save(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class NativeBannerProbe: NSObject, BannerViewDelegate {
    var received = 0
    var impressions = 0
    var errors: [String] = []
    func bannerViewDidReceiveAd(_ bannerView: BannerView) { received += 1 }
    func bannerViewDidRecordImpression(_ bannerView: BannerView) { impressions += 1 }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        errors.append("\((error as NSError).domain):\((error as NSError).code)")
    }
}
