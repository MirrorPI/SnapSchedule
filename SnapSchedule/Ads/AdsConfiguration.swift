import Foundation

/// Valid configuration is not consent or permission to start the SDK.
struct AdsConfiguration: Equatable, Sendable {
    enum Environment: String, Sendable { case debug, qa, production }
    enum DisabledReason: Equatable, Sendable {
        case sdkAppIDMismatch, environmentMismatch, missingIDs, invalidAppID, invalidBannerID
        case testIDsRequired, testIDsInProduction, publisherMismatch
    }
    struct IDs: Equatable, Sendable {
        let appID: String
        let bannerID: String
        fileprivate init(appID: String, bannerID: String) {
            self.appID = appID
            self.bannerID = bannerID
        }
    }
    enum State: Equatable, Sendable { case configured(IDs), disabled(DisabledReason) }
    let state: State
    private init(state: State) { self.state = state }

    static func resolve(environment: Environment, appID: String?, bannerID: String?) -> Self {
        guard let appID, let bannerID,
              !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bannerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self(state: .disabled(.missingIDs))
        }
        guard validID(appID, separator: "~") else { return Self(state: .disabled(.invalidAppID)) }
        guard validID(bannerID, separator: "/") else { return Self(state: .disabled(.invalidBannerID)) }
        switch environment {
        case .debug, .qa:
            guard appID == "ca-app-pub-3940256099942544~1458002511",
                  bannerID == "ca-app-pub-3940256099942544/2435281174" else {
                return Self(state: .disabled(.testIDsRequired))
            }
        case .production:
            let demoPublisher = "ca-app-pub-3940256099942544"
            guard !appID.hasPrefix(demoPublisher), !bannerID.hasPrefix(demoPublisher) else {
                return Self(state: .disabled(.testIDsInProduction))
            }
            guard appID.prefix(27) == bannerID.prefix(27) else {
                return Self(state: .disabled(.publisherMismatch))
            }
        }
        return Self(state: .configured(IDs(appID: appID, bannerID: bannerID)))
    }

    private static func validID(_ value: String, separator: Character) -> Bool {
        let prefix = "ca-app-pub-"
        guard value.hasPrefix(prefix) else { return false }
        let parts = value.dropFirst(prefix.count).split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 16, parts[1].count == 10 else { return false }
        return parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    static var buildEnvironment: Environment? {
        #if ADS_DEBUG && !ADS_QA && !ADS_PRODUCTION
        .debug
        #elseif ADS_QA && !ADS_DEBUG && !ADS_PRODUCTION
        .qa
        #elseif ADS_PRODUCTION && !ADS_DEBUG && !ADS_QA
        .production
        #else
        nil
        #endif
    }

    static var current: Self { load(info: Bundle.main.infoDictionary ?? [:], expectedEnvironment: buildEnvironment) }

    static func load(info: [String: Any], expectedEnvironment: Environment?) -> Self {
        guard let expectedEnvironment,
              let name = info["SnapScheduleAdsEnvironment"] as? String,
              Environment(rawValue: name) == expectedEnvironment else {
            return Self(state: .disabled(.environmentMismatch))
        }
        let configuration = resolve(environment: expectedEnvironment,
                                    appID: info["SnapScheduleAdsAppIdentifier"] as? String,
                                    bannerID: info["SnapScheduleBannerAdUnitIdentifier"] as? String)
        // The linked SDK verifies its plist App ID even before start(). A test bootstrap
        // identity keeps unconfigured Production launches safe, but is never an ad configuration.
        if case let .configured(ids) = configuration.state,
           info["GADApplicationIdentifier"] as? String != ids.appID {
            return Self(state: .disabled(.sdkAppIDMismatch))
        }
        return configuration
    }
}
