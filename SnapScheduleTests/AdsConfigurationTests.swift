import XCTest
@testable import SnapSchedule

final class AdsConfigurationTests: XCTestCase {
    private let testApp = "ca-app-pub-3940256099942544~1458002511"
    private let testBanner = "ca-app-pub-3940256099942544/2435281174"
    // Synthetic syntax fixtures only; never written to an app configuration or sent to Google.
    private let fixtureApp = "ca-app-pub-1234567890123456~1234567890"
    private let fixtureBanner = "ca-app-pub-1234567890123456/0987654321"

    func testDebugAndQAAcceptOnlyOfficialTestPair() {
        for env in [AdsConfiguration.Environment.debug, .qa] {
            guard case let .configured(ids) = AdsConfiguration.resolve(environment: env, appID: testApp, bannerID: testBanner).state else {
                return XCTFail("Official test configuration must be available")
            }
            XCTAssertEqual(ids.appID, testApp)
            XCTAssertEqual(ids.bannerID, testBanner)
            XCTAssertEqual(AdsConfiguration.resolve(environment: env, appID: fixtureApp, bannerID: fixtureBanner).state, .disabled(.testIDsRequired))
            XCTAssertEqual(AdsConfiguration.resolve(environment: env, appID: testApp, bannerID: fixtureBanner).state, .disabled(.testIDsRequired))
        }
    }

    func testMissingIDsDisableEveryEnvironment() {
        for env in [AdsConfiguration.Environment.debug, .qa, .production] {
            for (app, banner) in [(nil, nil), ("", testBanner), (testApp, ""), ("  ", testBanner)] as [(String?, String?)] {
                XCTAssertEqual(AdsConfiguration.resolve(environment: env, appID: app, bannerID: banner).state, .disabled(.missingIDs))
            }
        }
    }

    func testAppAndAdUnitIDCannotBeSwapped() {
        XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: fixtureBanner, bannerID: fixtureApp).state, .disabled(.invalidAppID))
        XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: fixtureApp, bannerID: fixtureApp).state, .disabled(.invalidBannerID))
    }

    func testProductionRejectsGoogleDemoPublisherIncludingOtherAdFormats() {
        for banner in [testBanner, "ca-app-pub-3940256099942544/2934735716", "ca-app-pub-3940256099942544/4411468910"] {
            XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: fixtureApp, bannerID: banner).state, .disabled(.testIDsInProduction))
        }
        XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: testApp, bannerID: fixtureBanner).state, .disabled(.testIDsInProduction))
    }

    func testProductionAcceptsMatchingPublisherSyntaxWithoutClaimingAccountVerification() {
        guard case let .configured(ids) = AdsConfiguration.resolve(environment: .production, appID: fixtureApp, bannerID: fixtureBanner).state else {
            return XCTFail("Valid syntax should configure IDs without contacting SDK")
        }
        XCTAssertEqual(ids.appID, fixtureApp)
        XCTAssertEqual(ids.bannerID, fixtureBanner)
    }

    func testMalformedOrUnexpandedIDsDisableProduction() {
        for app in ["$(ADS_APP_ID)", fixtureApp + "\n", " " + fixtureApp, "ca-app-pub-123~123", "ca-app-pub-１２３４５６７８９０１２３４５６~1234567890"] {
            XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: app, bannerID: fixtureBanner).state, .disabled(.invalidAppID))
        }
        for banner in ["$(ADS_BANNER_ID)", fixtureBanner + "\n", "not-an-id"] {
            XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: fixtureApp, bannerID: banner).state, .disabled(.invalidBannerID))
        }
    }

    func testMismatchedPublisherDisablesProduction() {
        XCTAssertEqual(AdsConfiguration.resolve(environment: .production, appID: fixtureApp, bannerID: "ca-app-pub-6543210987654321/0987654321").state, .disabled(.publisherMismatch))
    }

    func testBundleValuesLoadOnlyForCompiledEnvironment() {
        let info: [String: Any] = ["SnapScheduleAdsEnvironment": "qa", "GADApplicationIdentifier": testApp, "SnapScheduleAdsAppIdentifier": testApp, "SnapScheduleBannerAdUnitIdentifier": testBanner]
        guard case .configured = AdsConfiguration.load(info: info, expectedEnvironment: .qa).state else {
            return XCTFail("Matching QA build should expose validated test IDs")
        }
        XCTAssertEqual(AdsConfiguration.load(info: info, expectedEnvironment: .production).state, .disabled(.environmentMismatch))
        XCTAssertEqual(AdsConfiguration.load(info: info, expectedEnvironment: nil).state, .disabled(.environmentMismatch))
    }

    func testMissingUnknownAndWrongTypedBundleValuesFailClosed() {
        XCTAssertEqual(AdsConfiguration.load(info: [:], expectedEnvironment: .debug).state, .disabled(.environmentMismatch))
        XCTAssertEqual(AdsConfiguration.load(info: ["SnapScheduleAdsEnvironment": "Release"], expectedEnvironment: .qa).state, .disabled(.environmentMismatch))
        XCTAssertEqual(AdsConfiguration.load(info: ["SnapScheduleAdsEnvironment": "production", "GADApplicationIdentifier": 123], expectedEnvironment: .production).state, .disabled(.missingIDs))
    }

    func testBuiltAppConfigurationAndMeasurementDelay() {
        let environment = AdsConfiguration.buildEnvironment
        XCTAssertNotNil(environment)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SnapScheduleAdsEnvironment") as? String, environment?.rawValue)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADDelayAppMeasurementInit") as? Bool, true)
        if ProcessInfo.processInfo.arguments.contains("-Task421DesignRender"), environment == .debug,
           (Bundle.main.object(forInfoDictionaryKey: "SnapScheduleAdsAppIdentifier") as? String)?.isEmpty == true {
            XCTAssertEqual(AdsConfiguration.current.state, .disabled(.missingIDs))
            XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String, testApp)
            return
        }
        if environment == .production {
            if (Bundle.main.object(forInfoDictionaryKey: "SnapScheduleAdsAppIdentifier") as? String)?.isEmpty == true {
                XCTAssertEqual(AdsConfiguration.current.state, .disabled(.missingIDs))
                XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String, testApp)
            } else {
                guard case let .configured(ids) = AdsConfiguration.current.state else { return XCTFail("Supplied Production IDs should be validated") }
                XCTAssertEqual(ids.appID, Bundle.main.object(forInfoDictionaryKey: "SnapScheduleAdsAppIdentifier") as? String)
                XCTAssertEqual(ids.bannerID, Bundle.main.object(forInfoDictionaryKey: "SnapScheduleBannerAdUnitIdentifier") as? String)
                XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String, ids.appID)
            }
        } else {
            guard case let .configured(ids) = AdsConfiguration.current.state else { return XCTFail("Built QA/Debug app should use test IDs") }
            XCTAssertEqual(ids.appID, testApp)
            XCTAssertEqual(ids.bannerID, testBanner)
        }
    }

    func testSDKBootstrapIDCannotEnableMissingProductionConfiguration() {
        let info: [String: Any] = ["SnapScheduleAdsEnvironment": "production", "GADApplicationIdentifier": testApp,
                                  "SnapScheduleAdsAppIdentifier": "", "SnapScheduleBannerAdUnitIdentifier": fixtureBanner]
        XCTAssertEqual(AdsConfiguration.load(info: info, expectedEnvironment: .production).state, .disabled(.missingIDs))
    }

    func testSDKAppIDMustMatchValidatedConfigurationBeforeUse() {
        let info: [String: Any] = ["SnapScheduleAdsEnvironment": "production", "GADApplicationIdentifier": testApp,
                                  "SnapScheduleAdsAppIdentifier": fixtureApp, "SnapScheduleBannerAdUnitIdentifier": fixtureBanner]
        XCTAssertEqual(AdsConfiguration.load(info: info, expectedEnvironment: .production).state, .disabled(.sdkAppIDMismatch))
        var matching = info
        matching["GADApplicationIdentifier"] = fixtureApp
        guard case .configured = AdsConfiguration.load(info: matching, expectedEnvironment: .production).state else {
            return XCTFail("Matching validated production IDs should be available")
        }
        matching.removeValue(forKey: "GADApplicationIdentifier")
        XCTAssertEqual(AdsConfiguration.load(info: matching, expectedEnvironment: .production).state, .disabled(.sdkAppIDMismatch))
    }
}
