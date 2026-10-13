import SwiftUI

private struct ScreenshotThumbnailFactoryKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
        let loader = ScreenshotImageLoader(targetPixelSize: CGSize(width: 1024, height: 1024))
        return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { identifier, onPhase in
            try await loader.load(assetIdentifier: identifier, onPhase: onPhase)
        }
    }
}

extension EnvironmentValues {
    var screenshotThumbnailFactory: @MainActor (String) -> ScreenshotPreviewModel {
        get { self[ScreenshotThumbnailFactoryKey.self] }
        set { self[ScreenshotThumbnailFactoryKey.self] = newValue }
    }
}

/// Only the source image has fixed geometry. Text grows with Dynamic Type.
struct CandidateGalleryCard: View {
    @Environment(\.snapCompactTypography) private var compactTypography
    @Environment(\.screenshotThumbnailFactory) private var makeModel
    let candidate: ScheduleCandidate
    let imageHeight: CGFloat
    let onOpen: () -> Void
    let onIgnore: () -> Void
    var isSelecting = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CandidateGalleryImage(model: makeModel(candidate.sourceAssetIdentifier),
                                  candidate: candidate, onOpen: onOpen, onIgnore: onIgnore,
                                  isSelecting: isSelecting, isSelected: isSelected)
                .frame(height: imageHeight)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CandidateText.displayTitle(candidate)).font(compactTypography ? .subheadline.weight(.semibold) : .headline)
                    Text(CandidateText.dateAndTime(candidate)).font(.subheadline).foregroundStyle(.secondary)
                    Label {
                        Text(candidate.isRegistrationEligible ? String(localized: "Ready to register") : String(localized: "Review needed"))
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: candidate.isRegistrationEligible ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(candidate.isRegistrationEligible ? Color.green : Color.orange)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("candidate-detail-\(candidate.id)")
            .accessibilityLabel(CandidateText.accessibilityLabel(candidate))
            .accessibilityHint(isSelecting ? String(localized: "Selects or deselects this candidate for ignoring") : String(localized: "Opens candidate details"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
        }
    }
}

private struct CandidateGalleryImage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScreenshotPreviewModel
    let candidate: ScheduleCandidate
    let onOpen: () -> Void
    let onIgnore: () -> Void
    let isSelecting: Bool
    let isSelected: Bool

    init(model: ScreenshotPreviewModel, candidate: ScheduleCandidate,
         onOpen: @escaping () -> Void, onIgnore: @escaping () -> Void,
         isSelecting: Bool, isSelected: Bool) {
        _model = State(initialValue: model)
        self.candidate = candidate
        self.onOpen = onOpen
        self.onIgnore = onIgnore
        self.isSelecting = isSelecting
        self.isSelected = isSelected
    }

    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            ZStack(alignment: .topTrailing) {
                Button(action: onOpen) {
                    content
                        .frame(width: size.width, height: size.height)
                        .contentShape(CandidateGalleryOpenShape(), eoFill: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("candidate-image-\(candidate.id)")
                .accessibilityLabel(String(localized: "Original screenshot") + ", " + CandidateText.accessibilityLabel(candidate))
                .accessibilityHint(isSelecting ? String(localized: "Selects or deselects this candidate for ignoring") : String(localized: "Opens candidate details"))
                .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])

                if isSelecting {
                    Button(action: onOpen) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(SnapScheduleStyle.action)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("candidate-select-\(candidate.id)")
                    .accessibilityLabel(CandidateText.displayTitle(candidate))
                    .accessibilityHint(String(localized: "Selects or deselects this candidate for ignoring"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                } else {
                    Button(role: .destructive, action: onIgnore) {
                        Label(String(localized: "Ignore Candidate"), systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .tint(.red)
                    .accessibilityIdentifier("candidate-ignore-\(candidate.id)")
                    .accessibilityLabel(String(localized: "Ignore actions for \(CandidateText.displayTitle(candidate))"))
                    .accessibilityHint(String(localized: "Ignore this candidate without deleting its source photo"))
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { if model.status == .idle { model.load() } }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.load() }
            else { model.cancel() }
        }
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        guard let image = model.image, image.size.width > 0, image.size.height > 0 else { return available }
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .ready:
            if let image = model.image { Image(uiImage: image).resizable().scaledToFit() }
        default:
            ScreenshotImageStatusView(status: model.status, compact: true)
                .padding(.trailing, 44)
        }
    }
}

/// The 44pt X input is excluded from the photo's edit input, even though it overlays the image.
struct CandidateGalleryOpenShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(CGRect(x: max(rect.minX, rect.maxX - 44), y: rect.minY,
                            width: min(44, rect.width), height: min(44, rect.height)))
        return path
    }
}
