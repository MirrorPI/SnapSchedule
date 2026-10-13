import SwiftUI

/// Analysis is separate from the candidate's review/registration state.
struct HomeScanStatusView: View {
    let status: ScanStatus
    var identifier = "home-analysis-status"

    var body: some View {
        if isVisible {
            statusLabel
        }
    }

    // An empty new batch says nothing about the candidates still awaiting review.
    var isVisible: Bool {
        status.state != .completed || status.targetImageCount > 0
            || status.failedImageCount > 0 || status.lastErrorMessage != nil
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(SnapScheduleStyle.action)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            Text(statusTitle)
                .foregroundStyle(Color(uiColor: .label))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    var statusTitle: String {
        switch status.state {
        case .waiting:
            String(localized: "Waiting to analyze")
        case .discovering, .analyzing:
            String(localized: "Analyzing screenshots")
        case .completed:
            if status.failedImageCount > 0 || status.lastErrorMessage != nil {
                String(localized: "Analysis completed with failures")
            } else {
                String(localized: "Analysis complete")
            }
        case .completedWithFailures:
            String(localized: "Analysis completed with failures")
        case .failed:
            String(localized: "Analysis stopped")
        case .accessUnavailable:
            String(localized: "Photo access required")
        }
    }

    private var isBusy: Bool {
        status.state == .discovering || status.state == .analyzing
    }

    private var statusIcon: String {
        switch status.state {
        case .completed:
            status.failedImageCount > 0 || status.lastErrorMessage != nil
                ? "exclamationmark.triangle" : "checkmark.circle"
        case .completedWithFailures, .failed:
            "exclamationmark.triangle"
        case .accessUnavailable:
            "photo"
        case .waiting, .discovering, .analyzing:
            "clock"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .completed:
            status.failedImageCount > 0 || status.lastErrorMessage != nil
                ? .orange : SnapScheduleStyle.action
        case .completedWithFailures, .failed:
            .orange
        case .waiting, .discovering, .analyzing, .accessUnavailable:
            .secondary
        }
    }
}

struct CandidateReviewPresentation: Equatable {
    enum State { case empty, available, inProgress, completed }
    let state: State
    let pendingCount: Int

    init(candidates: [ScheduleCandidate], isEditing: Bool = false) {
        pendingCount = CandidateReviewSummary(candidates: candidates).pendingCount
        // Legacy undated rows hidden by the gallery are not evidence of completed review.
        let reviewed = candidates.contains { $0.date != nil && $0.reviewStatus != .pending }
        if candidates.contains(where: { $0.reviewStatus == .pending }) {
            state = isEditing || reviewed ? .inProgress : .available
        } else {
            state = reviewed ? .completed : .empty
        }
    }

    var title: String {
        switch state {
        case .empty: String(localized: "No candidates to review")
        case .available: String(localized: "Candidates awaiting review")
        case .inProgress: String(localized: "Candidate review in progress")
        case .completed: String(localized: "Candidate review complete")
        }
    }

    // Numeric badges fit the system tab. Analysis remains a separate status in the list.
    func badge(scanStatus: ScanStatus) -> String? {
        pendingCount > 0 ? (pendingCount > 99 ? "99+" : pendingCount.formatted()) : nil
    }

    var color: Color {
        switch state {
        case .completed: .green
        case .available, .inProgress: .orange
        case .empty: .secondary
        }
    }

    var symbol: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "clock"
        case .available, .empty: "photo.stack"
        }
    }

}

struct CandidateReviewStatusView: View {
    let presentation: CandidateReviewPresentation
    var body: some View {
        Label {
            Text(presentation.title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: presentation.symbol).foregroundStyle(presentation.color)
        }
        .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("candidate-review-status")
    }
}

enum HomeAnalysisPresentation: Equatable, Sendable {
    case waiting
    case analyzing
    case accessUnavailable
    case accessLimited
    case failed
    case empty
    case candidatesAvailable

    init(status: ScanStatus, pendingCandidateCount: Int) {
        switch status.state {
        case .discovering, .analyzing:
            self = .analyzing
        case .failed, .completedWithFailures:
            self = .failed
        case .accessUnavailable:
            self = status.photoAccess == .limited ? .accessLimited : .accessUnavailable
        case .waiting:
            self = .waiting
        case .completed:
            if status.lastErrorMessage != nil || status.failedImageCount > 0 {
                self = .failed
            } else if status.photoAccess == .limited {
                self = .accessLimited
            } else if !status.photoAccess.canReadAccessiblePhotos {
                self = .accessUnavailable
            } else if pendingCandidateCount == 0 {
                self = .empty
            } else {
                self = .candidatesAvailable
            }
        }
    }
}

struct ScanStatusView: View {
    let status: ScanStatus
    let candidateSummary: CandidateReviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                if status.state == .discovering || status.state == .analyzing {
                    ProgressView()
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if status.targetImageCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current batch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(
                        value: Double(status.completedImageCount + status.failedImageCount),
                        total: Double(status.targetImageCount)
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        metric(String(localized: "Target"), value: status.targetImageCount)
                        metric(String(localized: "Completed"), value: status.completedImageCount)
                        metric(String(localized: "Failed"), value: status.failedImageCount)
                        metric(String(localized: "Remaining"), value: status.pendingImageCount)
                    }
                    .font(.subheadline)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(
                    String(localized: "Pending candidates (all batches)"),
                    value: candidateSummary.pendingCount.formatted()
                )
                LabeledContent(String(localized: "Review needed"), value: candidateSummary.needsReviewCount.formatted())
                LabeledContent(String(localized: "Ready to register"), value: candidateSummary.readyCount.formatted())
            }
            .font(.subheadline)

            if status.photoAccess == .limited {
                Label(
                    String(localized: "Only screenshots allowed in limited photo access can be analyzed."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .tint(SnapScheduleStyle.action)
        .padding(.vertical, 8)
    }

    private func metric(_ title: String, value: Int) -> some View {
        LabeledContent(title, value: value.formatted())
    }

    private var statusTitle: String {
        switch status.state {
        case .waiting:
            String(localized: "Waiting to analyze")
        case .discovering:
            String(localized: "Finding screenshots")
        case .analyzing:
            String(localized: "Analyzing screenshots")
        case .completed:
            String(localized: "Analysis complete")
        case .completedWithFailures:
            String(localized: "Analysis completed with failures")
        case .failed:
            String(localized: "Analysis stopped")
        case .accessUnavailable:
            String(localized: "Photo access required")
        }
    }

    private var statusDetail: String {
        if case let .downloadingFromICloud(progress) = status.imageLoadPhase {
            return String(localized: "Downloading from iCloud \(Int(progress * 100))%")
        }
        if let message = status.lastErrorMessage {
            return message
        }
        switch status.state {
        case .waiting:
            return String(localized: "Analysis resumes the next time the app becomes active.")
        case .discovering:
            return String(localized: "The first scan may take a while. You can keep using the app.")
        case .analyzing:
            return String(localized: "You can keep using saved results while analysis continues.")
        case .completed:
            return status.targetImageCount == 0
                ? String(localized: "No new screenshots to analyze.")
                : String(localized: "All images in this batch were processed.")
        case .completedWithFailures:
            return String(localized: "Temporary failures will be retried on the next activation.")
        case .failed:
            return String(localized: "Analysis will try again on the next activation.")
        case .accessUnavailable:
            return String(localized: "Allow photo access to analyze screenshots automatically.")
        }
    }

    private var statusIcon: String {
        switch status.state {
        case .completed:
            "checkmark.circle.fill"
        case .completedWithFailures, .failed:
            "exclamationmark.triangle.fill"
        case .accessUnavailable:
            "exclamationmark.triangle"
        case .waiting, .discovering, .analyzing:
            "clock"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .completed:
            .green
        case .completedWithFailures, .failed:
            .orange
        case .accessUnavailable:
            .secondary
        case .waiting, .discovering, .analyzing:
            .accentColor
        }
    }
}
