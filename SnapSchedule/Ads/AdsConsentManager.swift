import Foundation
import Observation
import GoogleMobileAds
import UserMessagingPlatform
import SwiftUI
import UIKit
import AppTrackingTransparency

@MainActor
struct AdsTrackingAuthorization {
    var status: () -> ATTrackingManager.AuthorizationStatus
    var request: (@escaping @MainActor () -> Void) -> Void

    static var live: Self {
        Self(status: { ATTrackingManager.trackingAuthorizationStatus }, request: { done in
            ATTrackingManager.requestTrackingAuthorization { _ in
                Task { @MainActor in done() }
            }
        })
    }
}

@MainActor
struct AdsConsentSDK {
    typealias Completion = @MainActor (Error?) -> Void
    typealias Form = @MainActor (@escaping Completion) -> Void
    struct Snapshot {
        var canRequestAds: Bool
        var formRequired: Bool
        var privacyOptionsRequired: Bool
    }
    var snapshot: () -> Snapshot
    var update: (@escaping Completion) -> Void
    var loadForm: (@escaping @MainActor (Result<Form, Error>) -> Void) -> Void
    var privacyOptions: (@escaping Completion) -> Void
    var start: (@escaping @MainActor () -> Void) -> Void
}

/// One process-wide owner. No locally persisted consent flags and no ad loading here.
@MainActor @Observable
final class AdsConsentManager {
    static let shared = AdsConsentManager(configuration: .current, sdk: .live)
    enum State { case waiting, unavailable, allowed }
    private(set) var state = State.waiting
    /// A banner must dispose its view/request whenever this changes, including reselection.
    private(set) var revision = 0
    private(set) var privacyOptionsRequired = false
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    private let configured: Bool
    private let sdk: AdsConsentSDK
    private let tracking: AdsTrackingAuthorization
    private var launched = false
    private var operation = 0
    private enum Phase { case idle, tracking, updating, loading, pending, presenting, options }
    private var phase = Phase.idle
    private var sdkStarting = false
    private var sdkReady = false
    private var pendingForm: AdsConsentSDK.Form?
    private var homeIsSafe: () -> Bool = { false }

    var canRequestAds: Bool {
        configured && tracking.status() == .authorized && state == .allowed
            && !isBusy && sdkReady && sdk.snapshot().canRequestAds
    }

    init(configuration: AdsConfiguration, sdk: AdsConsentSDK, tracking: AdsTrackingAuthorization = .live) {
        if case .configured = configuration.state { configured = true } else { configured = false }
        self.sdk = sdk
        self.tracking = tracking
        if !configured { state = .unavailable }
    }

    func activate() {
        guard requireTrackingPermission(mayRequest: true) else { return }
        if !launched { launched = true; update() }
        else if phase == .idle { evaluate() }
        homeBecameAvailable()
    }

    func retry() {
        guard requireTrackingPermission(mayRequest: true), !isBusy, phase == .idle else { return }
        launched = true
        update()
    }

    func setHomePresentation(isSafe: @escaping () -> Bool) { homeIsSafe = isSafe }

    /// Every Google entry point is closed until the live OS permission is authorized.
    /// UMP consent does not replace ATT, and denial never blocks scheduling.
    private func requireTrackingPermission(mayRequest: Bool) -> Bool {
        guard configured else { return false }
        let status = tracking.status()
        if status == .authorized { return true }
        guard phase != .tracking else { return false }
        if state != .unavailable || phase != .idle || launched {
            operation += 1
            revision += 1
            launched = false
            phase = .idle
            pendingForm = nil
            sdkStarting = false
            isBusy = false
            privacyOptionsRequired = false
            errorMessage = nil
            state = .unavailable
        }
        guard mayRequest, status == .notDetermined, homeIsSafe() else { return false }
        operation += 1
        let ticket = operation
        phase = .tracking
        isBusy = true
        tracking.request { [weak self] in
            guard let self, self.operation == ticket, self.phase == .tracking else { return }
            self.phase = .idle
            self.isBusy = false
            // A transient notDetermined response waits for the next active Home;
            // never immediately loop another system permission request.
            if self.tracking.status() == .authorized, self.homeIsSafe() { self.activate() }
        }
        return false
    }

    private func invalidate() {
        revision += 1
        state = .waiting
    }

    private func update() {
        operation += 1
        let ticket = operation
        invalidate()
        phase = .updating
        isBusy = true
        errorMessage = nil
        sdk.update { [weak self] error in
            guard let self, self.operation == ticket, self.phase == .updating else { return }
            guard self.requireTrackingPermission(mayRequest: false) else { return }
            self.privacyOptionsRequired = self.sdk.snapshot().privacyOptionsRequired
            if let error { self.finish(error: error); return }
            if self.sdk.snapshot().formRequired {
                self.phase = .pending
                self.isBusy = false
                self.homeBecameAvailable()
            } else { self.finish(error: nil) }
        }
    }

    /// Rechecked after loading, so navigation/backgrounding cannot cause a late form over an editor.
    func homeBecameAvailable() {
        guard requireTrackingPermission(mayRequest: true) else { return }
        if !launched { activate(); return }
        guard phase == .pending, homeIsSafe() else { return }
        let ticket = operation
        if let form = pendingForm {
            pendingForm = nil
            phase = .presenting
            isBusy = true
            form { [weak self] error in
                guard let self, self.operation == ticket, self.phase == .presenting else { return }
                self.finish(error: error)
            }
        } else {
            phase = .loading
            isBusy = true
            sdk.loadForm { [weak self] result in
                guard let self, self.operation == ticket, self.phase == .loading else { return }
                guard self.requireTrackingPermission(mayRequest: false) else { return }
                switch result {
                case .success(let form):
                    self.pendingForm = form
                    self.phase = .pending
                    self.isBusy = false
                    self.homeBecameAvailable()
                case .failure(let error): self.finish(error: error)
                }
            }
        }
    }

    func presentPrivacyOptions() {
        guard requireTrackingPermission(mayRequest: false), privacyOptionsRequired, !isBusy,
              phase == .idle || phase == .pending else { return }
        operation += 1
        let ticket = operation
        pendingForm = nil
        invalidate()
        phase = .options
        isBusy = true
        errorMessage = nil
        sdk.privacyOptions { [weak self] error in
            guard let self, self.operation == ticket, self.phase == .options else { return }
            guard self.requireTrackingPermission(mayRequest: false) else { return }
            self.finish(error: error)
        }
    }

    private func finish(error: Error?) {
        phase = .idle
        isBusy = false
        pendingForm = nil
        errorMessage = error == nil ? nil : String(localized: "Ad privacy choices could not be updated. You can keep using all scheduling features and try again later.")
        evaluate()
    }

    private func evaluate() {
        guard requireTrackingPermission(mayRequest: false), phase == .idle else { return }
        let snapshot = sdk.snapshot()
        privacyOptionsRequired = snapshot.privacyOptionsRequired
        guard snapshot.canRequestAds else {
            if state == .allowed { revision += 1 }
            state = .unavailable
            return
        }
        guard sdkReady else {
            state = .waiting
            guard !sdkStarting else { return }
            sdkStarting = true
            sdk.start { [weak self] in
                // SDK initialization is process-wide, not a UMP operation. A
                // concurrent privacy-choice change must not strand sdkStarting.
                guard let self, !self.sdkReady,
                      self.requireTrackingPermission(mayRequest: false) else { return }
                self.sdkReady = true
                self.evaluate() // Read current UMP state, never a captured pre-reselection value.
            }
            return
        }
        state = .allowed
    }

    /// Task41 must obtain a fresh request here and match `revision` in load callbacks.
    /// This only constructs a request; it never sends or preloads an ad.
    func makeRequest() -> Request? {
        guard canRequestAds else { return nil }
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }
}

extension AdsConsentSDK {
    static var live: Self {
        Self(snapshot: {
            let info = ConsentInformation.shared
            return Snapshot(canRequestAds: info.canRequestAds,
                            formRequired: info.consentStatus == .required,
                            privacyOptionsRequired: info.privacyOptionsRequirementStatus == .required)
        }, update: { done in
            // ATT authorization is checked by the manager before any UMP call.
            ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { error in
                MainActor.assumeIsolated { done(error) }
            }
        }, loadForm: { done in
            ConsentForm.load { form, error in
                // UMP's Objective-C callback has no actor annotation. Its UI object
                // stays on the main queue; assert that contract before capturing it.
                dispatchPrecondition(condition: .onQueue(.main))
                nonisolated(unsafe) let loadedForm = form
                MainActor.assumeIsolated {
                    if let error { done(.failure(error)) }
                    else if let form = loadedForm {
                        done(.success { completion in
                            form.present(from: nil) { error in
                                MainActor.assumeIsolated { completion(error) }
                            }
                        })
                    } else { done(.failure(NSError(domain: "AdsConsent", code: 1))) }
                }
            }
        }, privacyOptions: { done in
            ConsentForm.presentPrivacyOptionsForm(from: nil) { error in
                MainActor.assumeIsolated { done(error) }
            }
        }, start: { done in
            MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
            MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState = .disabled
            MobileAds.shared.start { _ in
                Task { @MainActor in done() }
            }
        })
    }
}

/// Lives in Home's root content, not in the navigation container shared with editors.
struct AdsConsentHomeHost: UIViewControllerRepresentable {
    let manager: AdsConsentManager
    let eligible: Bool

    func makeUIViewController(context: Context) -> Host {
        Host(manager: manager)
    }
    func updateUIViewController(_ controller: Host, context: Context) {
        controller.eligible = eligible
        controller.installSafetyCheck()
        // Let SwiftUI finish updating the hierarchy before presenting or publishing state.
        Task { @MainActor [weak controller] in controller?.resume() }
    }
    final class Host: UIViewController {
        let manager: AdsConsentManager
        var eligible = false
        var visible = false
        init(manager: AdsConsentManager) { self.manager = manager; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            visible = true
            installSafetyCheck()
            resume()
        }
        override func viewWillDisappear(_ animated: Bool) {
            visible = false
            super.viewWillDisappear(animated)
        }
        func installSafetyCheck() {
            manager.setHomePresentation { [weak self] in
                guard let self, self.visible, self.eligible,
                      let window = self.viewIfLoaded?.window,
                      window.windowScene?.activationState == .foregroundActive else { return false }
                var controller: UIViewController? = self
                while let current = controller {
                    if current.presentedViewController != nil || current.isBeingDismissed { return false }
                    controller = current.parent
                }
                return true
            }
        }
        func resume() {
            guard eligible, visible else { return }
            manager.activate()
        }
    }
}
