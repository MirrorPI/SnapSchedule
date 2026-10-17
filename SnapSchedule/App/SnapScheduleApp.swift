import SwiftUI
import SwiftData

@main
struct SnapScheduleApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    private let modelContainer: ModelContainer
    @State private var scanCoordinator: ScanCoordinator

    init() {
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
