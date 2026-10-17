import SwiftUI
import SwiftData
import UIKit

@main
struct SnapScheduleApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    private let modelContainer: ModelContainer
    @State private var scanCoordinator: ScanCoordinator

    init() {
        AppSnapshotPrivacyShield.shared.start()
        do {
            let container = try SnapScheduleModelContainer.makeDefault()
            modelContainer = container
            NotificationRouteDiagnostics.record("app.modelContainerReady")
            let dataStore = LocalDataStore(container: container)
            _scanCoordinator = State(
                initialValue: ScanCoordinator(context: dataStore.context)
            )
        } catch {
            fatalError("Failed to create local model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView(
                scanCoordinator: scanCoordinator,
                notificationNavigation: notificationDelegate.navigationStore
            )
            .tint(SnapScheduleStyle.action)
        }
        .modelContainer(modelContainer)
    }
}

/// UIKit notifications are handled synchronously, before background snapshotting.
/// A separate window covers presented sheets as well as the main SwiftUI view.
@MainActor
final class AppSnapshotPrivacyShield: NSObject {
    static let shared = AppSnapshotPrivacyShield()

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var isObserving = false

    func start() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(coverScene(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(coverScene(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(revealScene(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(revealScene(_:)), name: UIScene.didDisconnectNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameVisible(_:)), name: UIWindow.didBecomeVisibleNotification, object: nil)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene.activationState != .foregroundActive {
            cover(scene)
        }
    }

    @objc private func coverScene(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        cover(scene)
    }

    @objc func revealScene(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        windows.removeValue(forKey: ObjectIdentifier(scene))?.isHidden = true
    }

    @objc private func windowBecameVisible(_ notification: Notification) {
        guard let window = notification.object as? UIWindow,
              let scene = window.windowScene,
              windows[ObjectIdentifier(scene)] !== window else { return }
        // Also cover windows created while inactive, without affecting another
        // scene that remains active. Never make the cover the key window: system
        // permission prompts must retain their normal focus and interaction.
        if windows[ObjectIdentifier(scene)] != nil || scene.activationState != .foregroundActive {
            cover(scene)
        }
    }

    private func cover(_ scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        let window: UIWindow
        if let existing = windows[key] {
            window = existing
        } else {
            window = UIWindow(windowScene: scene)
            window.accessibilityIdentifier = "AppSnapshotPrivacyShield"
            window.backgroundColor = .systemBackground
            window.isUserInteractionEnabled = false
            window.accessibilityElementsHidden = true
            let controller = UIViewController()
            controller.view.backgroundColor = .systemBackground
            controller.view.isOpaque = true
            window.rootViewController = controller
            // Register before changing visibility; its notification is synchronous.
            windows[key] = window
        }
        let highestOtherLevel = scene.windows.filter { $0 !== window }.map(\.windowLevel.rawValue).max() ?? 0
        window.windowLevel = UIWindow.Level(rawValue: max(UIWindow.Level.alert.rawValue, highestOtherLevel) + 1)
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
    }
}
