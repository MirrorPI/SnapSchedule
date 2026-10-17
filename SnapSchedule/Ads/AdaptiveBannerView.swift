import GoogleMobileAds
import Observation
import OSLog
import SwiftUI
import UIKit

/// Owns a single visible Home placement. No scheduling/photo data enters this boundary.
@MainActor @Observable
final class AdaptiveBannerController: NSObject, BannerViewDelegate, AdSizeDelegate {
    private(set) var banner: BannerView?
    private(set) var height: CGFloat = 0
    private let manager: AdsConsentManager
    private let configuration: AdsConfiguration
    private let load: (BannerView, Request) -> Void
    private struct Placement: Equatable {
        let width: CGFloat
        let maximumHeight: CGFloat
        let revision: Int
    }
    private var placement: Placement?
    private var received = false
    private var creativeHeight: CGFloat = 0
    nonisolated static let maximumHeight: CGFloat = 100
    private static let logger = Logger(subsystem: "SnapSchedule", category: "TestBanner")

    init(manager: AdsConsentManager, configuration: AdsConfiguration = .current,
         load: @escaping (BannerView, Request) -> Void = { $0.load($1) }) {
        self.manager = manager
        self.configuration = configuration
        self.load = load
        super.init()
    }

    func update(width: CGFloat, eligible: Bool, maximumHeight: CGFloat = AdaptiveBannerController.maximumHeight) {
        guard eligible, manager.canRequestAds, width.isFinite, width >= 320,
              maximumHeight.isFinite, maximumHeight >= 50, maximumHeight <= Self.maximumHeight,
              case let .configured(ids) = configuration.state else { stop(); return }
        // AdsConfiguration validates the ID pair for this build. Production uses
        // its own banner ID after the same live ATT and UMP checks as test builds.
        let next = Placement(width: floor(width), maximumHeight: floor(maximumHeight), revision: manager.revision)
        guard next != placement else { return } // Includes failures: no retry loop on body evaluation.
        dispose()
        placement = next
        guard let request = manager.makeRequest(), manager.revision == next.revision else {
            stop()
            return
        }
        let view = BannerView(adSize: inlineAdaptiveBanner(width: next.width, maxHeight: next.maximumHeight))
        view.adUnitID = ids.bannerID
        view.delegate = self
        view.adSizeDelegate = self
        view.isHidden = true
        banner = view
        Self.logger.notice("load width=\(next.width) maxHeight=\(next.maximumHeight) revision=\(next.revision)")
        load(view, request)
    }

    func stop() {
        dispose()
        placement = nil
    }

    private func dispose() {
        banner?.delegate = nil
        banner?.adSizeDelegate = nil
        banner?.rootViewController = nil
        banner?.removeFromSuperview()
        banner = nil
        height = 0
        creativeHeight = 0
        received = false
    }

    private func accepts(_ view: BannerView) -> Bool {
        guard banner === view else { return false }
        guard manager.canRequestAds, placement?.revision == manager.revision else {
            stop()
            return false
        }
        return true
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        guard accepts(bannerView) else { return }
        Self.logger.notice("received intrinsic=\(bannerView.intrinsicContentSize.width)x\(bannerView.intrinsicContentSize.height)")
        received = true
        // The initial intrinsic size is the requested maximum, not the creative size.
        // Only AdSizeDelegate's validated dimensions determine the creative's height.
        // The surrounding slot is already allocated and never follows these callbacks.
        showIfReady()
    }

    func adView(_ bannerView: BannerView, willChangeAdSizeTo size: AdSize) {
        guard accepts(bannerView) else { return }
        Self.logger.notice("size=\(size.size.width)x\(size.size.height)")
        acceptSize(size.size)
        showIfReady()
    }

    private func acceptSize(_ size: CGSize) {
        guard let placement, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.width <= placement.width,
              size.height > 0, size.height <= placement.maximumHeight else {
            dispose() // Reject an oversized creative rather than clipping its controls.
            return
        }
        creativeHeight = size.height
    }

    private func showIfReady() {
        guard received, creativeHeight > 0, let banner else { return }
        height = creativeHeight
        banner.isHidden = false
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        guard accepts(bannerView) else { return }
        Self.logger.notice("failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
        dispose() // Keep placement to avoid immediate retries after offline/no fill.
    }
}

/// Calculated synchronously from the safe content geometry, without consent/SDK requests.
struct AdaptiveBannerLayout: Equatable {
    let width: CGFloat
    let height: CGFloat

    init(size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets()) {
        width = max(0, floor(size.width - safeAreaInsets.leading - safeAreaInsets.trailing - 32))
        // Reserve a stable SDK-compatible slot from the usable viewport on every phone.
        let availableHeight = max(0, size.height - safeAreaInsets.top - safeAreaInsets.bottom)
        height = max(50, min(AdaptiveBannerController.maximumHeight, floor(availableHeight * 0.1)))
    }
}

/// A permanent Home slot. Empty/loading/no-fill/blocked states all retain its height.
struct AdaptiveBannerView: View {
    let controller: AdaptiveBannerController
    var reservedHeight: CGFloat = AdaptiveBannerController.maximumHeight
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if controller.height > 0, let banner = controller.banner {
                BannerContainer(banner: banner)
                    .frame(height: controller.height)
            }
        }
        .frame(height: reservedHeight + 24)
    }
}

/// Loading uses Home's preallocated layout, separately from creative callbacks.
/// Callers without an explicit layout retain safe-width measurement.
struct AdaptiveBannerLifecycle: ViewModifier {
    let manager: AdsConsentManager
    let controller: AdaptiveBannerController
    let eligible: Bool
    var layout: AdaptiveBannerLayout? = nil
    @State private var width: CGFloat = 0
    private struct Input: Equatable {
        let width: CGFloat
        let height: CGFloat
        let revision: Int
        let allowed: Bool
        let eligible: Bool
    }
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    let available = geometry.size.width - geometry.safeAreaInsets.leading
                        - geometry.safeAreaInsets.trailing - 32
                    Color.clear
                        .onAppear { width = available }
                        .onChange(of: available) { _, value in width = value }
                }
            }
            .task(id: Input(width: layout?.width ?? width, height: layout?.height ?? AdaptiveBannerController.maximumHeight,
                            revision: manager.revision,
                            allowed: manager.canRequestAds, eligible: eligible)) {
                controller.update(width: layout?.width ?? width, eligible: eligible,
                    maximumHeight: layout?.height ?? AdaptiveBannerController.maximumHeight)
            }
            .onDisappear { controller.stop() }
    }
}

// Keep the SDK view in the native UIView hierarchy. A child controller
// wrapper recorded impressions but left the creative white on iOS 17.2.
private struct BannerContainer: UIViewRepresentable {
    let banner: BannerView?
    func makeUIView(context: Context) -> BannerHostView { BannerHostView() }
    func updateUIView(_ view: BannerHostView, context: Context) {
        for old in view.subviews where old !== banner { old.removeFromSuperview() }
        guard let banner else { return }
        if banner.superview !== view {
            banner.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(banner)
        }
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: BannerHostView, coordinator: ()) {
        for case let banner as BannerView in view.subviews {
            banner.rootViewController = nil
            banner.removeFromSuperview()
        }
    }
}

private final class BannerHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let banner as BannerView in subviews {
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            banner.rootViewController = responder as? UIViewController
            let size = banner.adSize.size
            banner.frame = CGRect(x: (bounds.width - size.width) / 2,
                                  y: 0, width: size.width, height: bounds.height)
        }
    }
}
