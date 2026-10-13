import ImageIO
import Observation
import SwiftUI
import UIKit

enum ScreenshotPreviewStatus: Equatable {
    case idle
    case loadingLocal
    case downloadingFromICloud(progress: Double)
    case ready
    case retryable(ScreenshotImageLoadSource)
    case inaccessible

}

@MainActor
@Observable
final class ScreenshotPreviewModel {
    typealias LoadImage = @Sendable (
        _ assetIdentifier: String,
        _ onPhase: @escaping @Sendable (ScreenshotImageLoadPhase) -> Void
    ) async throws -> ScreenshotImageInput

    let sourceScreenshotIdentifier: String
    private(set) var status: ScreenshotPreviewStatus = .idle
    private(set) var image: UIImage?

    private let loadImage: LoadImage
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(
        sourceScreenshotIdentifier: String,
        loadImage: @escaping LoadImage
    ) {
        self.sourceScreenshotIdentifier = sourceScreenshotIdentifier
        self.loadImage = loadImage
    }

    func load() {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        image = nil
        status = .loadingLocal

        let sourceScreenshotIdentifier = sourceScreenshotIdentifier
        let loadImage = loadImage
        loadTask = Task { [weak self] in
            do {
                let input = try await loadImage(sourceScreenshotIdentifier) { [weak self] phase in
                    Task { @MainActor in
                        self?.apply(phase, generation: generation)
                    }
                }
                guard
                    !Task.isCancelled,
                    self?.loadGeneration == generation,
                    let decodedImage = Self.decode(input)
                else {
                    if !Task.isCancelled, self?.loadGeneration == generation {
                        self?.status = .retryable(.local)
                    }
                    return
                }
                self?.image = decodedImage
                self?.status = .ready
            } catch let error as ScreenshotImageLoadError {
                guard !Task.isCancelled, self?.loadGeneration == generation else { return }
                switch error {
                case let .retryable(source):
                    self?.status = .retryable(source)
                case .inaccessible:
                    self?.status = .inaccessible
                case .cancelled:
                    self?.status = .idle
                }
            } catch {
                guard !Task.isCancelled, self?.loadGeneration == generation else { return }
                self?.status = .retryable(.local)
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        image = nil
        status = .idle
    }

    private func apply(_ phase: ScreenshotImageLoadPhase, generation: Int) {
        guard loadGeneration == generation, loadTask?.isCancelled == false else { return }
        switch phase {
        case .loadingLocal:
            status = .loadingLocal
        case let .downloadingFromICloud(progress):
            status = .downloadingFromICloud(progress: progress)
        }
    }

    private static func decode(_ input: ScreenshotImageInput) -> UIImage? {
        guard let baseImage = UIImage(data: input.data) else { return nil }
        guard let cgImage = baseImage.cgImage else { return baseImage }
        return UIImage(
            cgImage: cgImage,
            scale: baseImage.scale,
            orientation: UIImage.Orientation(input.orientation)
        )
    }
}

struct ScreenshotPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScreenshotPreviewModel
    private var ownsModel = true

    init(model: ScreenshotPreviewModel) {
        _model = State(initialValue: model)
        ownsModel = false
    }

    init(
        sourceScreenshotIdentifier: String,
        loader: ScreenshotImageLoader = ScreenshotImageLoader()
    ) {
        _model = State(
            initialValue: ScreenshotPreviewModel(
                sourceScreenshotIdentifier: sourceScreenshotIdentifier,
                loadImage: { identifier, onPhase in
                    try await loader.load(assetIdentifier: identifier, onPhase: onPhase)
                }
            )
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Original Screenshot"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Close")) {
                            dismiss()
                        }
                        .accessibilityHint(String(localized: "Closes the original screenshot"))
                    }
                }
        }
        .onAppear {
            // Revalidate Photos access on every opening, including shared inline images.
            model.load()
        }
        .onDisappear {
            if ownsModel { model.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.status == .ready, let image = model.image {
            ZoomableScreenshotView(image: image)
                .ignoresSafeArea(edges: .bottom)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    ScreenshotImageStatusView(status: model.status, onRetry: { model.load() })
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
            }
        }
    }
}

/// Shared by the editors and details. The source remains untouched; the image
/// fits its natural aspect ratio and the existing full-screen viewer owns zoom.
struct ScreenshotInlineSection: View {
    @Environment(\.screenshotPreviewFactory) private var makeModel
    let sourceScreenshotIdentifier: String

    var body: some View {
        ScreenshotInlineContent(model: makeModel(sourceScreenshotIdentifier))
    }
}

/// A small preview/testing boundary; production always uses the existing PhotoKit loader.
private struct ScreenshotPreviewFactoryKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
        let loader = ScreenshotImageLoader()
        return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { identifier, onPhase in
            try await loader.load(assetIdentifier: identifier, onPhase: onPhase)
        }
    }
}

private struct ScreenshotCalendarThumbnailFactoryKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> ScreenshotPreviewModel = { identifier in
        let loader = ScreenshotImageLoader(targetPixelSize: CGSize(width: 128, height: 128))
        return ScreenshotPreviewModel(sourceScreenshotIdentifier: identifier) { identifier, onPhase in
            try await loader.load(assetIdentifier: identifier, onPhase: onPhase)
        }
    }
}

extension EnvironmentValues {
    var screenshotCalendarThumbnailFactory: @MainActor (String) -> ScreenshotPreviewModel {
        get { self[ScreenshotCalendarThumbnailFactoryKey.self] }
        set { self[ScreenshotCalendarThumbnailFactoryKey.self] = newValue }
    }

    var screenshotPreviewFactory: @MainActor (String) -> ScreenshotPreviewModel {
        get { self[ScreenshotPreviewFactoryKey.self] }
        set { self[ScreenshotPreviewFactoryKey.self] = newValue }
    }
}

private struct ScreenshotInlineContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScreenshotPreviewModel
    @State private var isShowingOriginal = false

    init(model: ScreenshotPreviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Label(String(localized: "Original Screenshot"), systemImage: "photo")
        }
        .onAppear {
            if model.status == .idle { model.load() }
        }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.load() }
        }
        .sheet(isPresented: $isShowingOriginal) {
            ScreenshotPreviewView(model: model)
        }
    }

    private var content: some View {
        ScreenshotImageContent(model: model, onOpen: { isShowingOriginal = true })
    }
}

/// Shared inline image/state presentation. The caller decides whether the image opens zoom or a schedule.
struct ScreenshotImageContent: View {
    let model: ScreenshotPreviewModel
    let onOpen: () -> Void
    var imageAccessibilityLabel = String(localized: "Original screenshot")
    var imageAccessibilityHint = String(localized: "Opens the full screenshot for zooming.")
    var imageAccessibilityIdentifier = "original-screenshot"
    var maximumImageHeight: CGFloat? = nil

    @ViewBuilder
    var body: some View {
        if model.status == .ready, let image = model.image {
            Button(action: onOpen) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maximumImageHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(imageAccessibilityLabel)
            .accessibilityHint(imageAccessibilityHint)
            .accessibilityIdentifier(imageAccessibilityIdentifier)
        } else {
            ScreenshotImageStatusView(status: model.status, onRetry: { model.load() })
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }
}

/// One state vocabulary for inline originals, full-screen originals and compact candidate images.
/// Loading and retry still belong to ScreenshotPreviewModel and its PhotoKit boundary.
struct ScreenshotImageStatusView: View {
    let status: ScreenshotPreviewStatus
    var onRetry: (() -> Void)? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch status {
            case .idle, .loadingLocal:
                ProgressView(String(localized: "Loading screenshot…"))
            case let .downloadingFromICloud(progress):
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Downloading original from iCloud…"))
                        .font(compact ? .caption : .subheadline)
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .ready, .inaccessible:
                unavailable(title: String(localized: "Screenshot Unavailable"),
                    symbol: "exclamationmark.triangle",
                    message: String(localized: "The original may have been deleted, removed from limited access, or made unavailable by Photos permission changes. Your saved candidate or schedule is unchanged."))
            case let .retryable(source):
                unavailable(title: String(localized: "Screenshot Could Not Be Loaded"),
                    symbol: source == .iCloud ? "icloud.slash" : "exclamationmark.triangle",
                    message: source == .iCloud
                        ? String(localized: "The original could not be downloaded from iCloud. Check your connection and try again.")
                        : String(localized: "The original could not be loaded. Please try again."))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func unavailable(title: String, symbol: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(compact ? .caption.weight(.semibold) : .headline)
            Text(compact ? String(localized: "Tap to review the saved candidate") : message)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
            if let onRetry {
                Button(String(localized: "Try Again"), action: onRetry)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
    }
}

/// Home originals share the editor's image component and existing bounded PhotoKit thumbnail request.
struct ScreenshotLinkedOriginal: View {
    @Environment(\.screenshotThumbnailFactory) private var makeModel
    let sourceScreenshotIdentifier: String
    let scheduleID: UUID
    let title: String
    let onOpen: () -> Void
    var body: some View {
        ScreenshotLinkedContent(model: makeModel(sourceScreenshotIdentifier), scheduleID: scheduleID,
                                title: title, onOpen: onOpen)
            .id(sourceScreenshotIdentifier)
    }
}

private struct ScreenshotLinkedContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ScreenshotPreviewModel
    let scheduleID: UUID
    let title: String
    let onOpen: () -> Void
    init(model: ScreenshotPreviewModel, scheduleID: UUID, title: String, onOpen: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.scheduleID = scheduleID; self.title = title; self.onOpen = onOpen
    }
    var body: some View {
        ScreenshotImageContent(model: model, onOpen: onOpen,
            imageAccessibilityLabel: String(localized: "Original screenshot") + ", " + title,
            imageAccessibilityHint: String(localized: "Opens schedule details"),
            imageAccessibilityIdentifier: "schedule-original-\(scheduleID)", maximumImageHeight: 320)
        .onAppear { if model.status == .idle { model.load() } }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.load() } else { model.cancel() }
        }
    }
}

private struct ZoomableScreenshotView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ScreenshotScrollView {
        let scrollView = ScreenshotScrollView()
        scrollView.delegate = context.coordinator
        return scrollView
    }

    func updateUIView(_ scrollView: ScreenshotScrollView, context: Context) {
        scrollView.display(image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ScreenshotScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ScreenshotScrollView)?.centerImage()
        }
    }
}

private final class ScreenshotScrollView: UIScrollView {
    let imageView = UIImageView()
    private var displayedImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 12
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        bouncesZoom = true

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "Original screenshot")
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ image: UIImage) {
        guard displayedImage !== image else { return }
        displayedImage = image
        imageView.image = image
        setZoomScale(minimumZoomScale, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == minimumZoomScale, let image = displayedImage else {
            centerImage()
            return
        }

        let availableSize = bounds.size
        guard availableSize.width > 0, availableSize.height > 0 else { return }
        let widthScale = availableSize.width / image.size.width
        let heightScale = availableSize.height / image.size.height
        let fittedScale = min(widthScale, heightScale)
        let fittedSize = CGSize(
            width: image.size.width * fittedScale,
            height: image.size.height * fittedScale
        )
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        centerImage()
    }

    func centerImage() {
        let horizontalInset = max(0, (bounds.width - contentSize.width) / 2)
        let verticalInset = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }
}

private extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
