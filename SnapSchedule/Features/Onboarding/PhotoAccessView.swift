import Photos
import PhotosUI
import SwiftUI
import UIKit

struct PhotoAccessView: View {
    let authorization: PhotoAuthorizationService
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbolName)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch authorization.access {
            case .notDetermined:
                Button(String(localized: "Continue")) {
                    Task {
                        await authorization.requestAccess()
                    }
                }
                .snapPrimaryAction()
            case .limited:
                VStack(alignment: .leading, spacing: 8) {
                    Button(String(localized: "Manage Selected Photos")) {
                        presentLimitedLibraryPicker()
                    }
                    Button(String(localized: "Open Settings")) {
                        openSettings()
                    }
                }
                .buttonStyle(.bordered)
            case .denied:
                Button(String(localized: "Open Settings")) {
                    openSettings()
                }
                .buttonStyle(.bordered)
            case .authorized, .restricted:
                EmptyView()
            }
        }
        .tint(SnapScheduleStyle.action)
        .controlSize(.regular)
        .padding(.vertical, 8)
    }

    private var title: String {
        switch authorization.access {
        case .notDetermined:
            String(localized: "Find schedules in screenshots")
        case .authorized:
            String(localized: "Full Photos access")
        case .limited:
            String(localized: "Limited Photos access")
        case .denied:
            String(localized: "Photos access is off")
        case .restricted:
            String(localized: "Photos access is restricted")
        }
    }

    private var message: String {
        switch authorization.access {
        case .notDetermined:
            String(localized: "Allow Photos access to start checking screenshots captured after setup. Existing photos are not analyzed or changed.")
        case .authorized:
            String(localized: "Screenshots captured after setup can be checked automatically when you open the app.")
        case .limited:
            String(localized: "Only selected screenshots captured after setup can be analyzed. New screenshots are not included unless you allow them.")
        case .denied:
            String(localized: "Screenshot analysis is unavailable, but you can keep using and reviewing your existing schedules.")
        case .restricted:
            String(localized: "This device prevents Photos access. You can keep using and reviewing your existing schedules.")
        }
    }

    private var symbolName: String {
        switch authorization.access {
        case .authorized:
            "photo.badge.checkmark"
        case .limited:
            "photo.on.rectangle.angled"
        case .denied, .restricted:
            "exclamationmark.triangle"
        case .notDetermined:
            "photo.stack"
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.keyWindow?.rootViewController else {
            return
        }

        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { _ in
            Task { @MainActor in
                authorization.refresh()
            }
        }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}

#Preview("Not determined") {
    PhotoAccessView(
        authorization: PhotoAuthorizationService(
            statusProvider: { .notDetermined },
            authorizationRequester: { .notDetermined }
        )
    )
    .padding()
}
