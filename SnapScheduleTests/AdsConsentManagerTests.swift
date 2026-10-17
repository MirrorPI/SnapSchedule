import XCTest
import GoogleMobileAds
import SwiftUI
import UIKit
import AppTrackingTransparency
@testable import SnapSchedule

@MainActor
final class AdsConsentManagerTests: XCTestCase {
    // Exercise the fake SDK independently of the app's disabled UI-test configuration.
    private var consentFixtureConfiguration: AdsConfiguration {
        AdsConfiguration.resolve(environment: .debug, appID: "ca-app-pub-3940256099942544~1458002511",
            bannerID: "ca-app-pub-3940256099942544/2435281174")
    }

    func testDeniedAndRestrictedTrackingNeverContactsGoogleEvenOnRetry() {
        for status: ATTrackingManager.AuthorizationStatus in [.denied, .restricted] {
            let sdk = ConsentSDKDouble()
            let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary,
                tracking: .init(status: { status }, request: { _ in XCTFail("Cannot reprompt a decided permission") }))
            manager.setHomePresentation(isSafe: { true })
            manager.activate()
            manager.retry()
            manager.presentPrivacyOptions()
            manager.homeBecameAvailable()
            XCTAssertTrue(sdk.updates.isEmpty)
            XCTAssertTrue(sdk.starts.isEmpty)
            XCTAssertTrue(sdk.options.isEmpty)
            XCTAssertFalse(manager.canRequestAds)
            XCTAssertNil(manager.makeRequest())
        }
    }

    func testTrackingPromptWaitsForSafeHomeAndSDKWaitsForAuthorization() {
        let sdk = ConsentSDKDouble()
        var status = ATTrackingManager.AuthorizationStatus.notDetermined
        var completion: (@MainActor () -> Void)?
        var prompts = 0
        var safe = false
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary,
            tracking: .init(status: { status }, request: { prompts += 1; completion = $0 }))
        manager.setHomePresentation(isSafe: { safe })
        manager.activate()
        XCTAssertTrue(sdk.updates.isEmpty)
        XCTAssertEqual(prompts, 0)
        safe = true
        manager.homeBecameAvailable()
        manager.activate()
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(sdk.updates.isEmpty)
        status = .authorized
        completion?()
        completion?()
        XCTAssertEqual(sdk.updates.count, 1)
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: false)
        sdk.updates.first?(nil)
        XCTAssertEqual(sdk.starts.count, 1)
        sdk.starts.first?()
        XCTAssertTrue(manager.canRequestAds)
    }

    func testTrackingDenialAfterPromptLeavesGoogleUncontacted() {
        let sdk = ConsentSDKDouble()
        var status = ATTrackingManager.AuthorizationStatus.notDetermined
        var completion: (@MainActor () -> Void)?
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary,
            tracking: .init(status: { status }, request: { completion = $0 }))
        manager.setHomePresentation(isSafe: { true })
        manager.activate()
        status = .denied
        completion?()
        manager.activate()
        manager.retry()
        XCTAssertTrue(sdk.updates.isEmpty)
        XCTAssertTrue(sdk.starts.isEmpty)
        XCTAssertFalse(manager.isBusy)
        XCTAssertFalse(manager.canRequestAds)
    }

    func testTrackingRevocationRejectsLateSDKCallbacksAndRequests() {
        let sdk = ConsentSDKDouble()
        var status = ATTrackingManager.AuthorizationStatus.authorized
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary,
            tracking: .init(status: { status }, request: { _ in XCTFail("Already decided") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        status = .denied
        sdk.updates.first?(nil)
        XCTAssertTrue(sdk.starts.isEmpty)
        manager.activate()
        manager.presentPrivacyOptions()
        XCTAssertTrue(sdk.options.isEmpty)
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertNil(manager.makeRequest())
    }

    func testAuthorizedSDKInitializationSurvivesConcurrentPrivacyOptions() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary,
            tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.updates.first?(nil)
        manager.presentPrivacyOptions()
        sdk.starts.first?()
        XCTAssertFalse(manager.canRequestAds)
        sdk.options.first?(nil)
        XCTAssertTrue(manager.canRequestAds)
        XCTAssertEqual(sdk.starts.count, 1)
    }
    func testNoPermissionBeforeUpdateAndDuplicateCallbacksStartOnlyOnce() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        XCTAssertFalse(manager.canRequestAds)
        manager.activate()
        manager.activate()
        XCTAssertEqual(sdk.updates.count, 1)
        guard sdk.updates.count == 1 else { return }
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: false)
        sdk.updates[0](nil)
        sdk.updates[0](nil)
        XCTAssertEqual(sdk.starts.count, 1)
        XCTAssertFalse(manager.canRequestAds)
        sdk.starts[0]()
        XCTAssertTrue(manager.canRequestAds)
        let revision = manager.revision
        manager.activate()
        XCTAssertEqual(manager.revision, revision)
        XCTAssertEqual(sdk.starts.count, 1)
    }

    func testFormWaitsForSafeHomeIncludingNavigationDuringLoad() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        var safe = false
        manager.setHomePresentation(isSafe: { safe })
        manager.activate()
        sdk.snapshot = .init(canRequestAds: false, formRequired: true, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        XCTAssertEqual(sdk.loads.count, 0)
        safe = true
        manager.homeBecameAvailable()
        XCTAssertEqual(sdk.loads.count, 1)
        safe = false
        var presentations = 0
        var finish: AdsConsentSDK.Completion?
        sdk.loads[0](.success { done in presentations += 1; finish = done })
        XCTAssertEqual(presentations, 0)
        safe = true
        manager.homeBecameAvailable()
        manager.homeBecameAvailable()
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(manager.canRequestAds)
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        finish?(nil)
        sdk.starts[0]()
        XCTAssertTrue(manager.canRequestAds)
        XCTAssertTrue(manager.privacyOptionsRequired)
    }

    func testPrivacyChangeInvalidatesBannerBeforePresentationAndRejectsLateCallbacks() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        sdk.starts[0]()
        let oldRevision = manager.revision
        manager.presentPrivacyOptions()
        manager.presentPrivacyOptions()
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertGreaterThan(manager.revision, oldRevision)
        XCTAssertEqual(sdk.options.count, 1)
        sdk.snapshot = .init(canRequestAds: false, formRequired: true, privacyOptionsRequired: true)
        sdk.options[0](nil)
        sdk.updates[0](nil)
        sdk.starts[0]()
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertEqual(sdk.starts.count, 1)
    }

    func testOfflineWithoutSDKPermissionStaysUnavailableButRetryWorks() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.updates[0](NSError(domain: "offline", code: -1009))
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertNotNil(manager.errorMessage)
        manager.retry()
        XCTAssertEqual(sdk.updates.count, 2)
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: false)
        sdk.updates[1](nil)
        sdk.starts[0]()
        XCTAssertTrue(manager.canRequestAds)
        XCTAssertNil(manager.errorMessage)
    }

    func testOfflineUsesSDKPreviousConsentAndRechecksLivePermission() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.updates[0](NSError(domain: "offline", code: -1009))
        sdk.starts[0]()
        XCTAssertTrue(manager.canRequestAds)
        sdk.snapshot.canRequestAds = false
        XCTAssertFalse(manager.canRequestAds)
        manager.activate()
        XCTAssertEqual(manager.state, .unavailable)
    }

    func testFormErrorAndPrivacyCancellationFollowSDKNotErrorOrStoredBoolean() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.setHomePresentation(isSafe: { true })
        manager.activate()
        sdk.snapshot = .init(canRequestAds: false, formRequired: true, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        sdk.loads[0](.failure(NSError(domain: "form", code: 1)))
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertNotNil(manager.errorMessage)
        manager.presentPrivacyOptions()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.options[0](NSError(domain: "cancel", code: 2))
        sdk.starts[0]()
        XCTAssertTrue(manager.canRequestAds)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testSDKInitializationCompletionCannotRestoreRevokedPermission() {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        manager.presentPrivacyOptions()
        sdk.starts[0]()
        XCTAssertFalse(manager.canRequestAds)
        sdk.snapshot.canRequestAds = false
        sdk.options[0](nil)
        XCTAssertFalse(manager.canRequestAds)
        manager.activate()
        XCTAssertEqual(sdk.starts.count, 1)
    }

    func testRequestFactoryRequiresLivePermissionAndAlwaysDisablesPersonalization() throws {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        XCTAssertNil(manager.makeRequest())
        manager.activate()
        sdk.snapshot = .init(canRequestAds: true, formRequired: false, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        XCTAssertNil(manager.makeRequest())
        sdk.starts[0]()
        let request = try XCTUnwrap(manager.makeRequest())
        let extras = try XCTUnwrap(request.adNetworkExtras(for: Extras.self) as? Extras)
        XCTAssertEqual(extras.additionalParameters?["npa"] as? String, "1")
        manager.presentPrivacyOptions()
        XCTAssertNil(manager.makeRequest())
        sdk.options[0](nil)
        XCTAssertNotNil(manager.makeRequest())
        sdk.snapshot.canRequestAds = false
        XCTAssertNil(manager.makeRequest())
    }

    func testSettingsShowsRequiredPrivacyEntryAndKeepsSchedulingControls() throws {
        guard case .configured = AdsConfiguration.current.state else {
            throw XCTSkip("Configured ad Settings UI is outside the intentionally disabled Task42-1 test host")
        }
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        sdk.snapshot = .init(canRequestAds: false, formRequired: false, privacyOptionsRequired: true)
        sdk.updates[0](NSError(domain: "offline", code: -1009))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let controller = UIHostingController(rootView: SettingsView(managesNotificationAuthorization: false,
            adsConsent: manager).environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func objects(_ object: NSObject) -> [NSObject] {
            var result: [NSObject] = []
            var seen = Set<ObjectIdentifier>()
            func visit(_ item: NSObject) {
                guard seen.insert(ObjectIdentifier(item)).inserted else { return }
                result.append(item)
                item.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(visit)
                (item as? UIView)?.subviews.forEach(visit)
            }
            visit(object)
            return result
        }
        var labels = Set(objects(controller.view).compactMap(\.accessibilityLabel))
        let scroll = try XCTUnwrap(objects(controller.view).compactMap { $0 as? UIScrollView }.first)
        for _ in 0..<4 {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height
                + scroll.adjustedContentInset.bottom)), animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            labels.formUnion(objects(controller.view).compactMap(\.accessibilityLabel))
        }
        for key in ["Day before", "Same day", "Ad privacy choices", "Retry ad privacy update"] {
            XCTAssertTrue(labels.contains { $0.contains(String(localized: String.LocalizationValue(key))) }, key)
        }
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "task40-settings-privacy-" + Locale.current.identifier
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPendingFormResumesAfterActualSheetDismissal() async throws {
        let sdk = ConsentSDKDouble()
        let manager = AdsConsentManager(configuration: consentFixtureConfiguration, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = AdsConsentHomeHost.Host(manager: manager)
        host.eligible = true
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sdk.updates.count, 1)
        guard sdk.updates.count == 1 else { return }
        sdk.snapshot = .init(canRequestAds: false, formRequired: true, privacyOptionsRequired: true)
        sdk.updates[0](nil)
        XCTAssertEqual(sdk.loads.count, 1)
        guard sdk.loads.count == 1 else { return }
        let settingsSheet = UIViewController()
        settingsSheet.modalPresentationStyle = .pageSheet
        let presented = expectation(description: "Settings sheet presented")
        host.present(settingsSheet, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 3)
        var presentations = 0
        sdk.loads[0](.success { _ in presentations += 1 })
        manager.homeBecameAvailable()
        XCTAssertEqual(presentations, 0)
        // Same completion hook used by Home's SwiftUI Settings sheet.
        let dismissed = expectation(description: "Settings sheet dismissed")
        host.dismiss(animated: false) {
            manager.homeBecameAvailable()
            dismissed.fulfill()
        }
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertEqual(presentations, 1, "visible=\(host.visible) eligible=\(host.eligible) window=\(host.viewIfLoaded?.window != nil) scene=\(scene.activationState.rawValue) presented=\(String(describing: host.presentedViewController)) dismissing=\(host.isBeingDismissed)")
    }

    func testDisabledConfigurationNeverContactsSDK() {
        let sdk = ConsentSDKDouble()
        let config = AdsConfiguration.resolve(environment: .production, appID: nil, bannerID: nil)
        let manager = AdsConsentManager(configuration: config, sdk: sdk.boundary, tracking: .init(status: { .authorized }, request: { _ in XCTFail("Already authorized") }))
        manager.activate()
        manager.retry()
        manager.presentPrivacyOptions()
        XCTAssertFalse(manager.canRequestAds)
        XCTAssertTrue(sdk.updates.isEmpty)
        XCTAssertTrue(sdk.starts.isEmpty)
    }
}

@MainActor
private final class ConsentSDKDouble {
    var snapshot = AdsConsentSDK.Snapshot(canRequestAds: false, formRequired: false, privacyOptionsRequired: false)
    var updates: [AdsConsentSDK.Completion] = []
    var loads: [(@MainActor (Result<AdsConsentSDK.Form, Error>) -> Void)] = []
    var options: [AdsConsentSDK.Completion] = []
    var starts: [@MainActor () -> Void] = []
    var boundary: AdsConsentSDK {
        .init(snapshot: { self.snapshot }, update: { self.updates.append($0) },
              loadForm: { self.loads.append($0) }, privacyOptions: { self.options.append($0) },
              start: { self.starts.append($0) })
    }
}
