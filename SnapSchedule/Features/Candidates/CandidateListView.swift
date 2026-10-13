import SwiftData
import SwiftUI

struct CandidateListView: View {
    @Environment(\.snapCompactTypography) private var compactTypography
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var storedCandidates: [ScheduleCandidate]
    @Query private var scans: [ScreenshotScan]
    @Bindable var selectionState: CandidateSelectionState
    let onOpenCandidate: (UUID) -> Void
    // Kept in the initializer for existing callers; registration uses Home's shared services in the editor.
    let notificationAuthorization: NotificationAuthorizationService
    let notificationScheduler: NotificationScheduler
    let scanStatus: ScanStatus?
    let reviewPresentation: CandidateReviewPresentation?
    @State private var dismissalRequestIDs: Set<UUID> = []
    @State private var isConfirmingDismissal = false
    @State private var isBatchDismissal = false
    private let dismissalSave: CandidateDismissalService.Save
    @State private var dismissalErrorMessage: String?
    @State private var galleryOrder: [UUID] = []

    init(selectionState: CandidateSelectionState, onOpenCandidate: @escaping (UUID) -> Void,
         notificationAuthorization: NotificationAuthorizationService = NotificationAuthorizationService(),
         notificationScheduler: NotificationScheduler = NotificationScheduler(),
         scanStatus: ScanStatus? = nil, reviewPresentation: CandidateReviewPresentation? = nil,
         dismissalSave: @escaping CandidateDismissalService.Save = { try $0.save() }) {
        _selectionState = Bindable(wrappedValue: selectionState)
        self.onOpenCandidate = onOpenCandidate
        self.notificationAuthorization = notificationAuthorization
        self.notificationScheduler = notificationScheduler
        self.scanStatus = scanStatus
        self.reviewPresentation = reviewPresentation
        self.dismissalSave = dismissalSave
    }

    private var pendingCandidates: [ScheduleCandidate] {
        CandidateListPresentation.orderedPending(storedCandidates, scans: scans, preserving: galleryOrder)
    }

    private var reviewSummary: CandidateReviewSummary { CandidateReviewSummary(candidates: storedCandidates) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: compactTypography ? 20 : 28) {
                    if let reviewPresentation {
                        CandidateReviewStatusView(presentation: reviewPresentation)
                        if let scanStatus {
                            HomeScanStatusView(status: scanStatus, identifier: "candidate-analysis-status")
                        }
                    }
                    summary
                    if pendingCandidates.isEmpty {
                        ContentUnavailableView(String(localized: "No candidates to review"), systemImage: "checkmark.circle",
                            description: Text(String(localized: "New candidates will appear here after screenshot analysis.")))
                    } else {
                        let columns = CandidateGalleryLayout.columnCount(count: pendingCandidates.count,
                            width: geometry.size.width, accessibility: dynamicTypeSize.isAccessibilitySize)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns),
                                  alignment: .center, spacing: 24) {
                            ForEach(pendingCandidates) { candidate in
                                CandidateGalleryCard(candidate: candidate,
                                    imageHeight: CandidateGalleryLayout.imageHeight(count: pendingCandidates.count,
                                        columns: columns, viewportHeight: geometry.size.height),
                                    onOpen: {
                                        if selectionState.isDismissSelectionActive {
                                            selectionState.toggleDismissSelection(candidate)
                                        } else {
                                            selectionState.openDetails(candidate.id)
                                            onOpenCandidate(candidate.id)
                                        }
                                    }, onIgnore: { requestDismissal([candidate.id], batch: false) },
                                    isSelecting: selectionState.isDismissSelectionActive,
                                    isSelected: selectionState.dismissalCandidateIDs.contains(candidate.id))
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(SnapScheduleStyle.action)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectionState.isDismissSelectionActive {
                    Button(String(localized: "Cancel selection")) { selectionState.cancelDismissSelection() }
                        .accessibilityIdentifier("candidate-selection-cancel")
                } else if !pendingCandidates.isEmpty {
                    Button(String(localized: "Select candidates")) {
                        selectionState.beginDismissSelection()
                    }
                    .accessibilityIdentifier("candidate-selection-start")
                }
            }
        }
        .onAppear(perform: synchronize)
        .onChange(of: pendingCandidates.map(\.id)) { _, _ in synchronize() }
        .confirmationDialog(String(localized: "Ignore \(dismissalRequestIDs.count) Candidates?"),
            isPresented: $isConfirmingDismissal, titleVisibility: .visible) {
                Button(String(localized: "Ignore \(dismissalRequestIDs.count) Candidates"), role: .destructive,
                       action: dismissCandidates)
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "Only these unregistered candidates will be ignored. Original photos and registered schedules are kept."))
            }
        .alert(String(localized: "Candidate Could Not Be Ignored"),
            isPresented: Binding(get: { dismissalErrorMessage != nil }, set: { if !$0 { dismissalErrorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: { Text(dismissalErrorMessage ?? String(localized: "Please try again.")) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent(String(localized: "Pending candidates"), value: reviewSummary.pendingCount.formatted())
                .font(compactTypography ? .headline : .title3.weight(.semibold))
                .foregroundStyle(SnapScheduleStyle.action)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { summaryMetrics }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { summaryMetrics }
            }
            if selectionState.isDismissSelectionActive {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "\(selectionState.dismissalCandidateIDs.count) candidates selected"))
                        .font(.headline).monospacedDigit()
                        .accessibilityIdentifier("candidate-selection-count")
                    Text(String(localized: "Tap candidates to select them for ignoring."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { selectionActions }
                        VStack(alignment: .leading, spacing: 12) { selectionActions }
                    }
                }
            } else {
                Text(String(localized: "Tap a screenshot to edit and register its candidate. Each X ignores only that candidate."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var summaryMetrics: some View {
        summaryMetric(String(localized: "Source photos"), value: Set(pendingCandidates.map(\.sourceAssetIdentifier)).count)
        summaryMetric(String(localized: "Review needed"), value: reviewSummary.needsReviewCount)
        summaryMetric(String(localized: "Ready to register"), value: reviewSummary.readyCount)
    }

    private func summaryMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value.formatted())")
    }

    private func synchronize() {
        galleryOrder = pendingCandidates.map(\.id)
        selectionState.synchronize(with: pendingCandidates)
    }

    @ViewBuilder
    private var selectionActions: some View {
        Button(String(localized: "Ignore selected candidates"), role: .destructive) {
            requestDismissal(selectionState.dismissalCandidateIDs, batch: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.red)
        .disabled(selectionState.dismissalCandidateIDs.isEmpty)
        .accessibilityIdentifier("candidate-dismiss-selected")
        Button(String(localized: "Clear selection")) { selectionState.clearDismissSelection() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(selectionState.dismissalCandidateIDs.isEmpty)
            .accessibilityIdentifier("candidate-selection-clear")
    }

    private func requestDismissal(_ ids: Set<UUID>, batch: Bool) {
        guard !ids.isEmpty else { return }
        // Freeze exactly the IDs represented by the visible confirmation count.
        dismissalRequestIDs = ids
        isBatchDismissal = batch
        isConfirmingDismissal = true
    }

    private func dismissCandidates() {
        do {
            if isBatchDismissal {
                try selectionState.dismissSelection(candidateIDs: dismissalRequestIDs, in: modelContext, save: dismissalSave)
            } else {
                guard let candidate = storedCandidates.first(where: { dismissalRequestIDs.contains($0.id) }) else {
                    throw CandidateDismissalError.selectionChanged
                }
                try selectionState.dismiss(candidate, in: modelContext, save: dismissalSave)
            }
        } catch CandidateDismissalError.selectionChanged {
            dismissalErrorMessage = String(localized: "Some candidates are no longer awaiting review. No candidates were ignored. Review your selection and try again.")
        } catch {
            dismissalErrorMessage = String(localized: "No candidates were ignored. Your selection has been kept. Please try again.")
        }
    }

}

/// Count rules refer to candidate cards, including cards sharing the same source photo.
enum CandidateGalleryLayout {
    static func columnCount(count: Int, width: CGFloat, accessibility: Bool) -> Int {
        if count <= 1 { return 1 }
        if accessibility { return 1 }
        if count <= 4 { return 2 }
        return width < 350 ? 2 : 3
    }

    static func imageHeight(count: Int, columns: Int, viewportHeight: CGFloat) -> CGFloat {
        if count == 1 { return max(240, viewportHeight - 230) }
        if count == 2 { return max(180, viewportHeight - 230) }
        if count <= 4 { return max(145, (viewportHeight - 260) / 2) }
        return columns == 1 ? 280 : 180
    }
}

enum CandidateText {
    static func displayTitle(_ candidate: ScheduleCandidate) -> String {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title == "일정 확인 필요" { return String(localized: "Schedule needs review") }
        return title.isEmpty ? String(localized: "Untitled candidate") : title
    }

    static func dateAndTime(_ candidate: ScheduleCandidate, locale: Locale = .current) -> String {
        if let date = candidate.date,
           let text = LocalizedDateText.dateTime(
                year: date.year, month: date.month, day: date.day,
                hour: candidate.time?.hour, minute: candidate.time?.minute,
                locale: locale
           ) { return text }
        let dateText = String(localized: "Date missing")
        guard let time = candidate.time else { return dateText }
        let timeText = LocalizedDateText.time(hour: time.hour, minute: time.minute, locale: locale)
        return String(localized: "\(dateText), \(timeText)")
    }

    static func accessibilityLabel(_ candidate: ScheduleCandidate) -> String {
        let reviewText = candidate.isRegistrationEligible ? String(localized: "Ready to register") : String(localized: "Review needed")
        return String(localized: "\(displayTitle(candidate)), \(dateAndTime(candidate)), source \(candidate.sourceAssetIdentifier), \(reviewText), Details")
    }
}
