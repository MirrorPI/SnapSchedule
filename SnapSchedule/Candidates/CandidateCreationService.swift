import Foundation
import CoreGraphics
import SwiftData

@MainActor
final class CandidateCreationService {
    typealias CandidateWillInsert = (ScheduleCandidate, Int) throws -> Void

    private let context: ModelContext
    private let scanQueue: ScanQueue
    private let candidateWillInsert: CandidateWillInsert

    init(
        context: ModelContext,
        scanQueue: ScanQueue,
        candidateWillInsert: @escaping CandidateWillInsert = { _, _ in }
    ) {
        self.context = context
        self.scanQueue = scanQueue
        self.candidateWillInsert = candidateWillInsert
    }

    // Counts only: no asset identifiers, titles, or OCR text are retained for diagnostics.
    private(set) var lastExclusions = CandidateExclusionCounts()

    @discardableResult
    func completeAnalysis(
        _ scan: ScreenshotScan,
        owner: UUID,
        drafts: [DateTimeCandidateDraft],
        fragments: [RecognizedTextFragment] = [],
        settings: AppSettings,
        analysisVersion: String?,
        analyzedAt: Date = .now
    ) throws -> [UUID] {
        var exclusions = CandidateExclusionCounts()
        var eligibleDrafts = drafts.filter { $0.date?.isValidGregorianDate == true }
        exclusions.undatedDraftCount = drafts.count - eligibleDrafts.count
        let schedules = try context.fetch(FetchDescriptor<Schedule>())
        if AppScreenEvidence.isClear(fragments: fragments, drafts: drafts, schedules: schedules) {
            exclusions.appScreenImageCount = 1
            exclusions.appScreenDraftCount = eligibleDrafts.count
            eligibleDrafts = []
        }
        let defaults = CandidateDefaults(settings: settings)
        var storedCandidateIDs: [UUID] = []

        try scanQueue.complete(
            scan,
            owner: owner,
            hasDateCandidates: !eligibleDrafts.isEmpty,
            analysisVersion: analysisVersion,
            analyzedAt: analyzedAt
        ) { [candidateWillInsert] context in
            let assetIdentifier = scan.assetIdentifier
            let descriptor = FetchDescriptor<ScheduleCandidate>(
                predicate: #Predicate { $0.sourceAssetIdentifier == assetIdentifier }
            )
            let existingCandidates = try context.fetch(descriptor)
            // Never merge, replace, or append to candidates already stored for this photo.
            if !existingCandidates.isEmpty {
                storedCandidateIDs = existingCandidates.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
                return
            }
            var handledKeys = Set<String>()
            let uniqueDrafts = eligibleDrafts.filter { handledKeys.insert($0.sourceKeyMaterial).inserted }
            guard let draft = uniqueDrafts.first else { return }
            let options = uniqueDrafts.map { value in
                CandidateDateEntry(date: value.date, time: value.time,
                    timeZoneIdentifier: value.timeZoneIdentifier,
                    reviewReasons: value.reviewReasons.map(CandidateReviewReason.init))
            }
            var reasons = draft.reviewReasons.map(CandidateReviewReason.init)
            if uniqueDrafts.count > 1, !reasons.contains(.ambiguousDate) { reasons.append(.ambiguousDate) }
            let candidate = ScheduleCandidate(
                sourceAssetIdentifier: assetIdentifier,
                sourceCandidateKey: draft.sourceKeyMaterial,
                evidenceText: draft.evidenceText,
                evidenceLocation: draft.evidenceLocation,
                title: draft.titleSuggestion,
                date: draft.date,
                time: draft.time,
                timeZoneIdentifier: draft.timeZoneIdentifier,
                reviewReasons: reasons,
                notifyDayBefore: defaults.notifyDayBefore,
                notifySameDay: defaults.notifySameDay,
                calendarExportRequested: defaults.calendarExportRequested
            )
            if options.count > 1 { candidate.recognizedDateOptions = options }
            try candidateWillInsert(candidate, 0)
            context.insert(candidate)
            storedCandidateIDs = [candidate.id]
        }

        lastExclusions = exclusions
        return storedCandidateIDs
    }
}

private extension CandidateReviewReason {
    init(_ reason: DateTimeReviewReason) {
        switch reason {
        case .yearInferredFromCaptureDate:
            self = .yearInferredFromCaptureDate
        case .yearInferredFromAnalysisDate:
            self = .yearInferredFromAnalysisDate
        case .relativeDate:
            self = .relativeDate
        case .relativeDateBasedOnAnalysisDate:
            self = .relativeDateBasedOnAnalysisDate
        case .missingDate:
            self = .missingDate
        case .unsupportedTimeZone:
            self = .unsupportedTimeZone
        case .timeZoneInferred:
            self = .timeZoneInferred
        case .missingTitle:
            self = .missingTitle
        case .ambiguousRange:
            self = .ambiguousRange
        case .uncertainTimeAssociation:
            self = .uncertainTimeAssociation
        case .timeRangeNotStored:
            self = .timeRangeNotStored
        case .possibleMetadataDate:
            self = .possibleMetadataDate
        }
    }
}

private struct CandidateDefaults {
    let notifyDayBefore: Bool
    let notifySameDay: Bool
    let calendarExportRequested: Bool

    @MainActor
    init(settings: AppSettings) {
        notifyDayBefore = settings.reminderDayBefore
        notifySameDay = settings.reminderSameDay
        calendarExportRequested = settings.defaultExportToCalendar
    }
}

struct CandidateExclusionCounts: Equatable, Sendable {
    var undatedDraftCount = 0
    var appScreenDraftCount = 0
    var appScreenImageCount = 0
}

private enum AppScreenEvidence {
    static func isClear(
        fragments: [RecognizedTextFragment],
        drafts: [DateTimeCandidateDraft],
        schedules: [Schedule]
    ) -> Bool {
        // Match complete OCR labels, across all supported UI languages, rather than
        // substrings in an event description. Weak OCR remains available for review.
        let labels = Set(fragments.filter { $0.confidence >= 0.8 }.map { normalize($0.text) })
        func has(_ variants: [String]) -> Bool {
            variants.contains { labels.contains(normalize($0)) }
        }
        let calendarCopy = has(["Calendar copy", "캘린더 사본", "カレンダーのコピー",
            "Apple Calendar copy", "Apple 캘린더 사본", "Appleカレンダーのコピー"])
        let original = has(["View Original Screenshot", "원본 스크린샷 보기", "元のスクリーンショットを表示",
            "Original Screenshot", "원본 스크린샷", "元のスクリーンショット"])
        let delete = has(["Delete Schedule", "일정 삭제", "予定を削除"])
        if calendarCopy && original && delete { return true }

        let analysis = has(["Screenshot analysis", "스크린샷 분석", "スクリーンショットの解析"])
        let review = has(["Candidate review", "후보 검수", "候補の確認", "Review schedules", "일정 확인", "予定を確認"])
        let reviewAction = has(["Review candidates", "후보 검수하기", "候補を確認"])
        if analysis && review && reviewAction { return true }

        if isCroppedCandidateEditor(fragments) { return true }

        let homeTab = has(["Home", "홈", "ホーム"])
        let settingsTab = has(["Settings", "설정", "設定"])
        let calendar = has(["Calendar", "캘린더", "달력", "カレンダー",
            "SnapSchedule calendar", "SnapSchedule 달력", "SnapScheduleのカレンダー",
            "ShotToSchedule calendar", "샷스케줄 달력", "ショットスケジュールのカレンダー"])
        // The three persistent tabs plus the calendar identify the new Home even
        // when large text pushes the selected-date section below the viewport.
        let shortReview = has(["Review", "予定確認"])
        let brandedCalendar = has(["SnapSchedule calendar", "SnapSchedule 달력", "SnapScheduleのカレンダー",
            "ShotToSchedule calendar", "샷스케줄 달력", "ショットスケジュールのカレンダー"])
        if homeTab && settingsTab && ((review && calendar) || (shortReview && brandedCalendar)) { return true }

        let includeDate = has(["Include date", "날짜 포함", "日付を含める"])
        let includeTime = has(["Include time", "시간 포함", "時刻を含める"])
        let export = has(["Add to Calendar after registration", "등록 후 캘린더에 추가", "登録後にカレンダーに追加",
            "Also add to Apple Calendar after registration", "등록 후 Apple 캘린더에도 추가", "登録後にAppleカレンダーにも追加"])
        if original && includeDate && includeTime && export { return true }
        // Candidate detail now shows the recognized date/time directly. Retain
        // legacy labels above for older screenshots and use its distinct options.
        let notifyBefore = has(["Notify one day before", "하루 전 알림", "前日に通知"])
        let notifyOnDay = has(["Notify on the day", "당일 알림", "当日に通知"])
        if original && export && notifyBefore && notifyOnDay { return true }

        // A cropped detail screen needs both app-specific option labels and a
        // registered event match. Matching an external event alone never excludes it.
        let dayBefore = has(["One day before", "하루 전", "前日"])
        let sameDay = has(["On the day", "당일", "当日"])
        guard calendarCopy && dayBefore && sameDay else { return false }
        let datedDrafts = drafts.filter { $0.date?.isValidGregorianDate == true }
        // Multiple dated events are ambiguous in a cropped screenshot. Never build
        // a registered-event match from one event's title and another event's date.
        guard datedDrafts.count == 1, let draft = datedDrafts.first else { return false }
        let timedDrafts = drafts.filter { $0.time != nil }
        return schedules.contains { schedule in
            let title = normalize(schedule.title)
            let titleMatches = normalize(draft.titleSuggestion) == title
                || (draft.reviewReasons.contains(.missingTitle) && labels.contains(title))
            guard !title.isEmpty, titleMatches, draft.date == schedule.date else { return false }
            guard let time = schedule.time else { return timedDrafts.isEmpty }
            // Detail forms place time on its own row. Accept that row only when
            // exactly one parsed time exists; conflicting times remain reviewable.
            guard timedDrafts.count == 1, let timedDraft = timedDrafts.first else { return false }
            return timedDraft.time == time && timedDraft.timeZoneIdentifier == schedule.timeZoneIdentifier
        }
    }

    private static func isCroppedCandidateEditor(_ fragments: [RecognizedTextFragment]) -> Bool {
        // Vision often reports 0.5 for correctly read CJK labels. This separate
        // rule requires nine exact labels in their form/tab positions; it does
        // not lower the confidence threshold of the existing whole-screen rules.
        func one(_ labels:[String], in region:CGRect) -> RecognizedTextFragment? {
            let matches=fragments.filter { f in
                f.confidence >= 0.5 && labels.contains { normalize($0) == normalize(f.text) }
                    && region.contains(CGPoint(x:f.boundingBox.midX,y:f.boundingBox.midY))
            }
            return matches.count == 1 ? matches.first : nil
        }
        let tabs=CGRect(x:0,y:0,width:1,height:0.18)
        guard let review=one(["Candidate review","후보 검수","候補の確認","Review schedules","일정 확인","予定を確認"],in:tabs),
              let home=one(["Home","홈","ホーム"],in:tabs),
              let settings=one(["Settings","설정","設定"],in:tabs),
              review.boundingBox.maxX < home.boundingBox.minX,
              home.boundingBox.maxX < settings.boundingBox.minX,
              abs(review.boundingBox.midY-home.boundingBox.midY) <= 0.04,
              abs(home.boundingBox.midY-settings.boundingBox.midY) <= 0.04 else { return false }
        let form=CGRect(x:0,y:0.08,width:0.65,height:0.87)
        guard let input=one(["Enter your own title","직접 입력","直接入力"],in:form),
              let evidence=one(["Evidence","인식 근거","認識の根拠"],in:form),
              let confirmation=one(["Confirm the inferred time zone","추정한 시간대 확인","推定されたタイムゾーンを確認"],in:form),
              let before=one(["Notify one day before","하루 전 알림","前日に通知"],in:form),
              let onDay=one(["Notify on the day","당일 알림","当日に通知"],in:form),
              input.boundingBox.minY > evidence.boundingBox.maxY,
              evidence.boundingBox.minY > confirmation.boundingBox.maxY,
              confirmation.boundingBox.minY > before.boundingBox.maxY,
              before.boundingBox.minY > onDay.boundingBox.maxY,
              onDay.boundingBox.minY > review.boundingBox.maxY else { return false }
        // A separately read evidence date below its label is the ninth form clue.
        return fragments.contains { f in
            f.confidence >= 0.8 && f.boundingBox.maxY < evidence.boundingBox.minY
                && f.boundingBox.minY > confirmation.boundingBox.maxY
                && abs(f.boundingBox.minX-evidence.boundingBox.minX) <= 0.05
                && !DateTimeParser().parse(fragments:[f],captureDate:nil,analysisDate:.now,
                    timeZone:TimeZone(secondsFromGMT:0)!).filter { $0.date?.isValidGregorianDate == true }.isEmpty
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined()
    }
}
