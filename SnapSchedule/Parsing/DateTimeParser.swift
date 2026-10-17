import CoreGraphics
import Foundation

enum DateTimeReviewReason: String, Equatable, Hashable, Sendable {
    case yearInferredFromCaptureDate
    case yearInferredFromAnalysisDate
    case relativeDate
    case relativeDateBasedOnAnalysisDate
    case missingDate
    case unsupportedTimeZone
    case timeZoneInferred
    case missingTitle
    case ambiguousRange
    case uncertainTimeAssociation
    case timeRangeNotStored
    case possibleMetadataDate
}

enum DateTimeRangeRole: String, Equatable, Sendable {
    case standalone
    case start
    case end
}

struct DateTimeCandidateDraft: Equatable, Sendable {
    let titleSuggestion: String
    let date: CalendarDate?
    let time: ClockTime?
    let timeZoneIdentifier: String?
    let evidenceText: String
    let evidenceLocation: NormalizedRect
    let reviewReasons: [DateTimeReviewReason]
    let rangeRole: DateTimeRangeRole
    let sourceKeyMaterial: String

    var requiresReview: Bool {
        !reviewReasons.isEmpty
    }
}

struct DateTimeParser: Sendable {
    // Bound work before regex/context matching. Reject the entire OCR result;
    // truncation could remove a date qualifier and create an incorrect schedule.
    static let maximumFragmentCount = 256
    static let maximumTextUTF16Count = 8_000

    static func acceptsInput(_ fragments: [RecognizedTextFragment]) -> Bool {
        guard fragments.count <= maximumFragmentCount else { return false }
        var remaining = maximumTextUTF16Count
        for fragment in fragments {
            // A bounded UTF-16 traversal also handles huge grapheme clusters
            // without first counting every Character in an untrusted string.
            let count = fragment.text.utf16.prefix(remaining + 1).count
            guard count <= remaining else { return false }
            remaining -= count
        }
        return true
    }

    func parse(
        fragments: [RecognizedTextFragment],
        captureDate: Date?,
        analysisDate: Date,
        timeZone: TimeZone
    ) -> [DateTimeCandidateDraft] {
        guard Self.acceptsInput(fragments) else { return [] }
        let inputs = Self.joinSplitMeridiem(in: fragments)
        let parsed = inputs.map { input in
            let fragment = input.fragment
            return Self.segments(in: fragment).enumerated().flatMap { segmentIndex, segment in
                parse(
                    segment: segment,
                    fragmentIndex: input.index,
                    segmentIndex: segmentIndex,
                    captureDate: captureDate,
                    analysisDate: analysisDate,
                    timeZone: timeZone
                )
            }
        }
        let datedIndices = Set(zip(inputs, parsed).compactMap { input, drafts in
            drafts.contains { $0.date != nil } ? input.index : nil
        })
        let drafts = zip(inputs, parsed).flatMap { input, drafts in
            // A multi-candidate clause cannot safely share surrounding context.
            guard drafts.count == 1, let draft = drafts.first, draft.date != nil else {
                return drafts
            }
            return [Self.addNearbyContext(to: draft, anchor: input, inputs: inputs, datedIndices: datedIndices)]
        }
        // Keep source indices/keys intact. Only a distinct note metadata row is
        // removed; body dates, ranges, titled dates and uncertain layouts survive.
        let metadataKeys = Self.noteMetadataKeys(in: drafts, fragments: fragments)
        return Self.contestSubmissionDeadlines(
            in: drafts.filter { !metadataKeys.contains($0.sourceKeyMaterial) }, fragments: fragments
        )
    }

    private static func contestSubmissionDeadlines(
        in drafts: [DateTimeCandidateDraft], fragments: [RecognizedTextFragment]
    ) -> [DateTimeCandidateDraft] {
        // A submission period belongs to one contest. Keep its deadline, rather
        // than turning its opening and closing dates into two separate events.
        // Ordinary ranges, competing contest titles and uncertain OCR survive.
        let headings = fragments.filter { fragment in
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fragment.confidence >= 0.5, text.count <= 120,
                  let marker = regexMatches(#"(?i)공모전|\b(?:contest|competition)\b|コンテスト|コンクール"#, in: text).first,
                  !text.contains("공모전 대외활동"),
                  (fullDatePatterns + partialDatePatterns).allSatisfy({ regexMatches($0, in: text).isEmpty })
            else { return false }
            let prefix = (text as NSString).substring(to: marker.range.location)
            return prefix.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
        }.sorted { $0.text.count > $1.text.count }
        guard let heading = headings.first else { return drafts }
        func compact(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { !$0.isWhitespace && !$0.isPunctuation }
        }
        let title = compact(heading.text)
        let genericContestTitle = #"(?i)^(?:(?:단편|대국민|미소|사진|영화|photo(?:graphy)?|short|film|写真|短編|映画)\s*)+(?:공모전|contest|competition|コンテスト|コンクール)$"#
        guard headings.allSatisfy({ other in
            let otherTitle = compact(other.text)
            // Generic poster category text may repeat inside the full event
            // name. Extra proper-name words still identify another contest.
            return title == otherTitle || (title.contains(otherTitle)
                && !regexMatches(genericContestTitle, in: other.text.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty)
        }) else {
            return drafts
        }
        let periodLabel = #"(?i)^(?:(?:접수|응모|모집)\s*기간|応募期間|募集期間|(?:submission|entry|application)\s+period)\s*[:：]?"#
        func isPeriodRemainder(_ text: String) -> Bool {
            if text == "일정 확인 필요" { return true }
            let remainder = text.replacingOccurrences(of: periodLabel, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\bD\s*-\s*\d+\b"#, with: "", options: .regularExpression)
            return remainder.allSatisfy { $0.isWhitespace || $0.isPunctuation }
        }
        func clauseKey(_ draft: DateTimeCandidateDraft) -> String {
            draft.sourceKeyMaterial.components(separatedBy: "|candidate:")[0]
        }
        let clauses = Dictionary(grouping: drafts, by: clauseKey)
        let periods = clauses.values.compactMap { clause -> (start: DateTimeCandidateDraft, end: DateTimeCandidateDraft)? in
            guard clause.count == 2, let start = clause.first(where: { $0.rangeRole == .start }),
                  let end = clause.first(where: { $0.rangeRole == .end }),
                  start.date?.isValidGregorianDate == true, end.date?.isValidGregorianDate == true,
                  start.evidenceText == end.evidenceText, isPeriodRemainder(end.titleSuggestion),
                  [start, end].allSatisfy({ !$0.reviewReasons.contains(.ambiguousRange)
                      && !$0.reviewReasons.contains(.uncertainTimeAssociation) }),
                  fragments.contains(where: { $0.confidence >= 0.5 && $0.text.contains(end.evidenceText) })
            else { return nil }
            return (start, end)
        }
        guard let first = periods.first, periods.allSatisfy({ $0.end.date == first.end.date
            && $0.end.time == first.end.time && $0.end.timeZoneIdentifier == first.end.timeZoneIdentifier })
        else { return drafts }
        // Prefer the explicit submission table over a repeated poster range.
        let ordered = periods.sorted { lhs, rhs in
            let leftLabeled = !regexMatches(periodLabel, in: lhs.end.evidenceText).isEmpty
            let rightLabeled = !regexMatches(periodLabel, in: rhs.end.evidenceText).isEmpty
            if leftLabeled != rightLabeled { return leftLabeled }
            return drafts.firstIndex(of: lhs.end)! < drafts.firstIndex(of: rhs.end)!
        }
        let chosen = ordered[0].end
        let removed = Set(periods.flatMap { [$0.start.sourceKeyMaterial, $0.end.sourceKeyMaterial] })
        let b = chosen.evidenceLocation
        let location = CGRect(x: b.x, y: b.y, width: b.width, height: b.height).union(heading.boundingBox)
        let deadline = DateTimeCandidateDraft(
            titleSuggestion: String(heading.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            date: chosen.date, time: chosen.time, timeZoneIdentifier: chosen.timeZoneIdentifier,
            evidenceText: heading.text + "\n" + chosen.evidenceText,
            evidenceLocation: NormalizedRect(x: location.minX, y: location.minY, width: location.width, height: location.height),
            reviewReasons: chosen.reviewReasons.filter { $0 != .missingTitle },
            rangeRole: chosen.rangeRole, sourceKeyMaterial: chosen.sourceKeyMaterial
        )
        return drafts.compactMap { draft in
            if draft.sourceKeyMaterial == chosen.sourceKeyMaterial { return deadline }
            return removed.contains(draft.sourceKeyMaterial) ? nil : draft
        }
    }

    private static func noteMetadataKeys(
        in drafts: [DateTimeCandidateDraft], fragments: [RecognizedTextFragment]
    ) -> Set<String> {
        let dated = drafts.filter { $0.date?.isValidGregorianDate == true }
        guard dated.count >= 2 else { return [] }
        // Geometry by itself also describes multi-date flyers. Require the
        // editable note's formatting strip and keyboard toggle as independent
        // chrome clues. Screenshots without these remain available for review.
        let formatting = fragments.contains { f in
            let text=f.text.trimmingCharacters(in:.whitespacesAndNewlines)
            return f.confidence >= 0.5 && ["Aa","가가"].contains(text)
                && f.boundingBox.minX <= 0.20 && (0.25...0.55).contains(f.boundingBox.midY)
        }
        let keyboard = fragments.contains { f in
            f.confidence >= 0.5 && f.text.trimmingCharacters(in:.whitespacesAndNewlines) == "123"
                && f.boundingBox.minX <= 0.20 && f.boundingBox.maxY <= 0.20
        }
        guard formatting && keyboard else { return [] }
        func box(_ draft: DateTimeCandidateDraft) -> CGRect {
            let b = draft.evidenceLocation
            return CGRect(x:b.x,y:b.y,width:b.width,height:b.height)
        }
        return Set(dated.compactMap { header in
            let h = box(header)
            guard header.rangeRole == .standalone, header.time != nil,
                  header.reviewReasons.contains(.missingTitle), h.minY >= 0.80,
                  h.height > 0, h.height <= 0.03, (0.40...0.60).contains(h.midX),
                  let anchor = fragments.first(where: {
                      $0.confidence >= 0.8 && $0.boundingBox == h
                          && $0.text == header.evidenceText
                  }) else { return nil }
            let titleLines = fragments.filter { f in
                let b=f.boundingBox, gap=h.minY-b.maxY
                return f.confidence >= 0.5 && b.minX <= 0.20 && b.height >= h.height * 1.3
                    && gap >= 0 && gap <= 0.04 && !f.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                    && !f.text.contains("\n")
            }
            guard titleLines.count == 1, let title = titleLines.first else { return nil }
            let body = dated.contains { other in
                guard other.sourceKeyMaterial != header.sourceKeyMaterial,
                      other.date != header.date, other.rangeRole == .standalone,
                      !other.reviewReasons.contains(.missingTitle) else { return false }
                return fragments.contains { f in
                    let b=f.boundingBox, gap=title.boundingBox.minY-b.maxY
                    return f.confidence >= 0.8 && gap >= 0 && gap <= 0.04
                        && abs(b.minX-title.boundingBox.minX) <= 0.04
                        && other.evidenceText.contains(f.text)
                        && other.evidenceText.contains(title.text)
                        && b.maxY < anchor.boundingBox.minY
                }
            }
            return body ? header.sourceKeyMaterial : nil
        })
    }

    private func parse(
        segment: TextSegment,
        fragmentIndex: Int,
        segmentIndex: Int,
        captureDate: Date?,
        analysisDate: Date,
        timeZone: TimeZone
    ) -> [DateTimeCandidateDraft] {
        let text = segment.text
        guard !text.isEmpty, !Self.looksLikeVersion(text) else { return [] }

        let basis = captureDate ?? analysisDate
        let inferredYear = Self.components(of: basis, in: timeZone).year!
        let inferenceReason: DateTimeReviewReason = captureDate == nil
            ? .yearInferredFromAnalysisDate
            : .yearInferredFromCaptureDate

        var dateMatches = Self.explicitDateMatches(
            in: text,
            inferredYear: inferredYear,
            inferenceReason: inferenceReason,
            timeZone: timeZone
        )
        dateMatches.append(contentsOf: Self.relativeDateMatches(
            in: text,
            basis: basis,
            analysisDate: analysisDate,
            usedAnalysisDate: captureDate == nil,
            timeZone: timeZone
        ))
        dateMatches.sort { $0.range.location < $1.range.location }
        dateMatches = Self.addOmittedRangeEndIfPresent(
            in: text,
            matches: dateMatches,
            timeZone: timeZone
        )
        let timeMatches = Self.timeMatches(in: text)
        let timeZoneResults = timeMatches.map { Self.explicitTimeZone(in: text, after: $0.range) }
        dateMatches = Self.applyRangeInheritance(
            in: text,
            matches: dateMatches,
            timeMatches: timeMatches,
            timeZoneResults: timeZoneResults
        )
        if dateMatches.isEmpty,
           timeMatches.count == 1,
           Self.isStandaloneStatusBarTime(
               text: text,
               timeRange: timeMatches[0].range,
               boundingBox: segment.boundingBox
           ) {
            return []
        }

        guard !dateMatches.isEmpty || !timeMatches.isEmpty else { return [] }

        let timeAssignments = Self.assignTimes(
            in: text,
            dateMatches: dateMatches,
            timeMatches: timeMatches,
            timeZoneResults: timeZoneResults
        )
        let assignedTimeIndices = Set(timeAssignments.byDate.values)
        var drafts: [DateTimeCandidateDraft] = []
        let rangeRoles = Self.rangeRoles(
            in: text,
            dateMatches: dateMatches,
            timeMatches: timeMatches,
            timeZoneResults: timeZoneResults
        )

        for (dateIndex, dateMatch) in dateMatches.enumerated() {
            let timeIndex = timeAssignments.byDate[dateIndex]
            let time = timeIndex.map { timeMatches[$0].time }
            let timeZoneResult = timeIndex.map { timeZoneResults[$0] }
            var reasons = dateMatch.reviewReasons
            if timeAssignments.uncertainDates.contains(dateIndex) {
                reasons.append(.uncertainTimeAssociation)
            }
            if timeAssignments.rangeDates.contains(dateIndex) {
                reasons.append(.timeRangeNotStored)
            }
            if timeZoneResult?.isUnsupported == true {
                reasons.append(.unsupportedTimeZone)
            }
            if time != nil, timeZoneResult?.range == nil {
                reasons.append(.timeZoneInferred)
            }
            drafts.append(makeDraft(
                segment: segment,
                fragmentIndex: fragmentIndex,
                segmentIndex: segmentIndex,
                candidateIndex: drafts.count,
                text: text,
                date: dateMatch.date,
                time: time,
                timeZoneIdentifier: time == nil
                    ? nil
                    : (timeZoneResult?.identifier ?? timeZone.identifier),
                reviewReasons: reasons,
                rangeRole: rangeRoles[dateIndex],
                removalRanges: dateMatches.map(\.range)
                    + timeMatches.map(\.range)
                    + timeZoneResults.compactMap(\.range)
            ))
        }

        for (timeIndex, timeMatch) in timeMatches.enumerated()
        where !assignedTimeIndices.contains(timeIndex) {
            var reasons: [DateTimeReviewReason] = [.missingDate]
            let timeZoneResult = timeZoneResults[timeIndex]
            if timeZoneResult.isUnsupported {
                reasons.append(.unsupportedTimeZone)
            }
            if timeZoneResult.range == nil {
                reasons.append(.timeZoneInferred)
            }
            drafts.append(makeDraft(
                segment: segment,
                fragmentIndex: fragmentIndex,
                segmentIndex: segmentIndex,
                candidateIndex: drafts.count,
                text: text,
                date: nil,
                time: timeMatch.time,
                timeZoneIdentifier: timeZoneResult.identifier ?? timeZone.identifier,
                reviewReasons: reasons,
                rangeRole: .standalone,
                removalRanges: timeMatches.map(\.range)
                    + timeZoneResults.compactMap(\.range)
            ))
        }

        return drafts
    }

    private func makeDraft(
        segment: TextSegment,
        fragmentIndex: Int,
        segmentIndex: Int,
        candidateIndex: Int,
        text: String,
        date: CalendarDate?,
        time: ClockTime?,
        timeZoneIdentifier: String?,
        reviewReasons: [DateTimeReviewReason],
        rangeRole: DateTimeRangeRole,
        removalRanges: [NSRange]
    ) -> DateTimeCandidateDraft {
        let dateKey = date.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "no-date"
        let timeKey = time.map { "\($0.hour):\($0.minute)" } ?? "no-time"
        let titleSuggestion = Self.titleSuggestion(from: text, removing: removalRanges)
        var reasons = reviewReasons
        if titleSuggestion == "일정 확인 필요" {
            reasons.append(.missingTitle)
        }
        let firstExpression = removalRanges.min { $0.location < $1.location }
        let sourceLabel = firstExpression.map { (text as NSString).substring(to: $0.location) }
        if Self.isMetadataLabel(titleSuggestion) || (date != nil && sourceLabel.map(Self.isMetadataLabel) == true) {
            reasons.append(.possibleMetadataDate)
        }
        return DateTimeCandidateDraft(
            titleSuggestion: titleSuggestion,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            evidenceText: reasons.contains(.uncertainTimeAssociation) || reasons.contains(.timeRangeNotStored)
                ? text : String(text.prefix(160)),
            evidenceLocation: NormalizedRect(
                x: segment.boundingBox.origin.x,
                y: segment.boundingBox.origin.y,
                width: segment.boundingBox.width,
                height: segment.boundingBox.height
            ),
            reviewReasons: Self.uniqued(reasons),
            rangeRole: rangeRole,
            sourceKeyMaterial: "fragment:\(fragmentIndex)|segment:\(segmentIndex):\(segment.utf16Range.location)|candidate:\(candidateIndex)|\(rangeRole.rawValue)|\(dateKey)|\(timeKey)"
        )
    }
}

private extension DateTimeParser {
    struct IndexedFragment {
        let index: Int
        var fragment: RecognizedTextFragment
    }

    static func isPM(_ marker: String) -> Bool {
        marker == "오후" || marker.lowercased().replacingOccurrences(of: ".", with: "") == "pm"
    }

    static func isMeridiem(_ text: String) -> Bool {
        text.range(of: #"(?i)^(?:AM|PM|A\.M\.|P\.M\.|오전|오후)$"#,
                   options: .regularExpression) != nil
    }

    static func joinSplitMeridiem(in fragments: [RecognizedTextFragment]) -> [IndexedFragment] {
        var inputs = fragments.enumerated().map { IndexedFragment(index: $0.offset, fragment: $0.element) }
        var consumed = Set<Int>()
        for markerIndex in inputs.indices {
            let marker = inputs[markerIndex].fragment
            guard marker.confidence >= 0.5,
                  isMeridiem(marker.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let matches = inputs.indices.filter { index in
                guard index != markerIndex, !consumed.contains(index) else { return false }
                let clock = inputs[index].fragment
                let box = clock.boundingBox
                let markerBox = marker.boundingBox
                let height = max(box.height, markerBox.height)
                guard clock.confidence >= 0.5, height > 0,
                      abs(box.midY - markerBox.midY) <= height * 0.4 else { return false }
                let after = markerBox.minX >= box.maxX - height * 0.2
                    && markerBox.minX - box.maxX <= height * 1.5
                    && clock.text.range(of: #"(?<!\d)(?:[01]?\d|2[0-3]):[0-5]\d\s*$"#,
                                        options: .regularExpression) != nil
                let before = box.minX >= markerBox.maxX - height * 0.2
                    && box.minX - markerBox.maxX <= height * 1.5
                    && clock.text.range(of: #"^\s*(?:[01]?\d|2[0-3]):[0-5]\d(?!\d)"#,
                                        options: .regularExpression) != nil
                return after || before
            }
            guard matches.count == 1, let index = matches.first else { continue }
            let clock = inputs[index].fragment
            let markerFirst = marker.boundingBox.minX < clock.boundingBox.minX
            inputs[index].fragment = RecognizedTextFragment(
                text: markerFirst ? "\(marker.text) \(clock.text)" : "\(clock.text) \(marker.text)",
                boundingBox: clock.boundingBox.union(marker.boundingBox),
                confidence: min(clock.confidence, marker.confidence)
            )
            consumed.insert(markerIndex)
        }
        return inputs.filter { !consumed.contains($0.index) }
    }

    static func isPlaceText(_ text: String) -> Bool {
        // Retain explicit location labels or clear place nouns, never infer a location.
        let pattern = #"(?i)^(?:장소|위치|Location|Venue)\s*[:：]\s*\S|(?:역|공항|회의실|센터|홀|병원|도서관|Station|Hall|Hotel)\s*$"#
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: .regularExpression) != nil
    }

    static func isFormLabel(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"(?i)^(?:Date|Time|Title|Location|Venue|Evidence|날짜|시간|제목|장소|위치|근거|日付|時刻|タイトル|場所|認識の根拠)\s*[:：]?$"#,
                   options: .regularExpression) != nil
    }

    // A date label can describe metadata rather than an event. Keep its date
    // available for review; this is neither an event classifier nor an exclusion.
    static func isMetadataLabel(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"(?i)^(?:작성일|작성\s*시각|게시일|발행일|메모\s*작성\s*시각|Published(?:\s+(?:on|at))?|Posted(?:\s+(?:on|at))?|Created(?:\s+(?:on|at))?|投稿日|公開日|作成日|作成日時|달력|Calendar|カレンダー)\s*[:：]?$"#,
                   options: .regularExpression) != nil
    }

    static func addNearbyContext(
        to draft: DateTimeCandidateDraft,
        anchor: IndexedFragment,
        inputs: [IndexedFragment],
        datedIndices: Set<Int>
    ) -> DateTimeCandidateDraft {
        let box = anchor.fragment.boundingBox
        guard anchor.fragment.confidence >= 0.5, box.height > 0 else { return draft }

        func nearbyLine(above: Bool) -> IndexedFragment? {
            let neighbors = inputs.filter { input in
                guard input.index != anchor.index else { return false }
                let other = input.fragment.boundingBox
                let height = max(box.height, other.height)
                let gap = above ? other.minY - box.maxY : box.minY - other.maxY
                return gap >= -height * 0.15 && gap <= height * 1.5
                    && abs(box.minX - other.minX) <= height * 0.75
            }
            // Do not choose between competing lines/columns or skip an unreadable neighbor.
            guard neighbors.count == 1, let neighbor = neighbors.first,
                  neighbor.fragment.confidence >= 0.5, !datedIndices.contains(neighbor.index) else { return nil }
            let text = neighbor.fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 60, !isMeridiem(text),
                  !looksLikeVersion(text), timeMatches(in: text).isEmpty,
                  regexMatches(#"\d{1,4}[.\-/]\d{1,2}|\d{1,4}[년월일年月日]|내일|모레|이번\s*주"#, in: text).isEmpty
            else { return nil }
            // One title/place must not be assigned to two nearby dated events.
            let competingAnchor = inputs.contains { other in
                guard other.index != anchor.index, other.index != neighbor.index,
                      abs(other.fragment.boundingBox.minX - neighbor.fragment.boundingBox.minX)
                        <= max(other.fragment.boundingBox.height, neighbor.fragment.boundingBox.height) * 0.75,
                      datedIndices.contains(other.index) ||
                        !regexMatches(#"\d{1,4}[.\-/]\d{1,2}|\d{1,4}[년월일年月日]|내일|모레|이번\s*주"#,
                                      in: other.fragment.text).isEmpty else { return false }
                return abs(other.fragment.boundingBox.midY - neighbor.fragment.boundingBox.midY)
                    <= abs(box.midY - neighbor.fragment.boundingBox.midY)
                        + max(box.height, neighbor.fragment.boundingBox.height) * 0.25
            }
            return competingAnchor ? nil : neighbor
        }

        let above = nearbyLine(above: true)
        let below = nearbyLine(above: false)
        let titleLine = above.flatMap { input -> IndexedFragment? in
            guard draft.reviewReasons.contains(.missingTitle),
                  !isPlaceText(input.fragment.text), !isFormLabel(input.fragment.text) else { return nil }
            return input
        }
        let placeLine = [below, above].compactMap { $0 }.first { isPlaceText($0.fragment.text) }
        guard titleLine != nil || placeLine != nil else { return draft }
        var title = titleLine?.fragment.text ?? draft.titleSuggestion
        // A place alone does not establish an event title; preserve missingTitle.
        if let placeLine, !draft.reviewReasons.contains(.missingTitle) || titleLine != nil,
           title.count + placeLine.fragment.text.count + 3 <= 60 {
            title += " · " + placeLine.fragment.text
        }
        let context = [titleLine, anchor, placeLine].compactMap { $0 }
            .sorted { $0.fragment.boundingBox.midY > $1.fragment.boundingBox.midY }
        let evidenceBox = context.reduce(box) { $0.union($1.fragment.boundingBox) }
        let evidence = context.map(\.fragment.text).joined(separator: "\n")
        var reasons = draft.reviewReasons.filter { $0 != .missingTitle || titleLine == nil }
        if isMetadataLabel(titleLine?.fragment.text ?? draft.titleSuggestion),
           !reasons.contains(.possibleMetadataDate) {
            reasons.append(.possibleMetadataDate)
        }
        return DateTimeCandidateDraft(
            titleSuggestion: title, date: draft.date, time: draft.time,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            evidenceText: String(evidence.prefix(160)),
            evidenceLocation: NormalizedRect(x: evidenceBox.minX, y: evidenceBox.minY,
                                             width: evidenceBox.width, height: evidenceBox.height),
            reviewReasons: reasons,
            rangeRole: draft.rangeRole, sourceKeyMaterial: draft.sourceKeyMaterial
        )
    }

    struct TextSegment {
        let text: String
        let utf16Range: NSRange
        let boundingBox: CGRect
    }

    struct DateMatch {
        var date: CalendarDate
        let range: NSRange
        var reviewReasons: [DateTimeReviewReason]
        let hasExplicitYear: Bool
    }

    struct TimeMatch {
        let time: ClockTime
        let range: NSRange
    }

    struct TimeZoneResult {
        let identifier: String?
        let range: NSRange?
        let isUnsupported: Bool
    }

    static func segments(in fragment: RecognizedTextFragment) -> [TextSegment] {
        let text = fragment.text as NSString
        let separators = regexMatches(
            #"\s+(?:/|\|)\s+|\s*[·•]\s*|[,、，]\s*|;\s*|\n+"#,
            in: fragment.text
        ).filter { separator in
            // Keep a date's annotation or qualifier in the same clause.
            // Splitting "Wednesday, next week" would erase its modifier.
            guard let first = text.substring(with:separator.range).first,
                  ",、，".contains(first) else { return true }
            let prefix=text.substring(to:separator.range.location)
            let suffix=text.substring(from:NSMaxRange(separator.range))
            let hasTrailingDate=([koreanWeekdayPattern, englishWeekdayPattern, japaneseWeekdayPattern] + dayOnlyPatterns).contains {
                !regexMatches($0 + #"\s*$"#,in:prefix).isEmpty
            }
            let hasTrailingQualifier = !regexMatches(#"(?i)"# + nearestDateQualifierPattern + #"\s*$"#,in:prefix).isEmpty
            let hasFollowingDate = ([koreanWeekdayPattern, englishWeekdayPattern, japaneseWeekdayPattern] + dayOnlyPatterns).contains {
                !regexMatches($0,in:suffix).isEmpty
            }
            return !((hasTrailingDate && (beginsWrittenDate(suffix) || startsDateQualifier(suffix)))
                || (hasTrailingQualifier && hasFollowingDate))
        }
        var rawRanges: [NSRange] = []
        var start = 0
        for separator in separators {
            if separator.range.location > start {
                rawRanges.append(NSRange(
                    location: start,
                    length: separator.range.location - start
                ))
            }
            start = NSMaxRange(separator.range)
        }
        if start < text.length {
            rawRanges.append(NSRange(location: start, length: text.length - start))
        }

        return rawRanges.compactMap { rawRange in
            let trimmedRange = trimmingWhitespace(in: text, range: rawRange)
            guard trimmedRange.length > 0 else { return nil }
            let totalLength = max(text.length, 1)
            let startFraction = CGFloat(trimmedRange.location) / CGFloat(totalLength)
            let widthFraction = CGFloat(trimmedRange.length) / CGFloat(totalLength)
            let box = fragment.boundingBox
            return TextSegment(
                text: text.substring(with: trimmedRange),
                utf16Range: trimmedRange,
                boundingBox: CGRect(
                    x: box.minX + box.width * startFraction,
                    y: box.minY,
                    width: box.width * widthFraction,
                    height: box.height
                )
            )
        }
    }

    static let fullDatePatterns = [
        #"(?<![\d./-])(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})(?![\d./-])"#,
        #"(?<!\d)(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일"#,
        #"(?<!\d)(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日"#,
    ]
    static let partialDatePatterns = [
        #"(?<![\d./])(\d{1,2})[./](\d{1,2})(?![\d./])"#,
        #"(?<!\d)(\d{1,2})월\s*(\d{1,2})일"#,
        #"(?<!\d)(\d{1,2})月\s*(\d{1,2})日"#,
    ]
    static let koreanWeekdayPattern = #"(?<![가-힣])(?:이번\s*주\s*)?([월화수목금토일])요일(?:\s*(?:까지|에))?"#
    static let japaneseWeekdayPattern = #"([月火水木金土日])曜(?:日)?(?:\s*(?:まで(?:に)?|に))?"#
    static let englishWeekdayPattern = #"(?i)\b(?:(?:by|until|on)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\b\.?"#

    static let englishMonthNamePattern = #"(?:january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)"#
    static let dayOnlyPatterns = [
        #"(?<![\d年月월년./-])(\d{1,2})\s*일(?:\s*(?:까지|에)|(?![가-힣]))"#,
        #"(?<![\d年月월년./-])(\d{1,2})\s*日(?:\s*(?:まで(?:に)?|に))?(?![間前後目])"#,
        #"(?i)\b(?:(?:by|until|on)\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#
    ]
    // Qualified dates need their own interpretation. Never silently discard a
    // written month/year or next/last modifier to apply the nearest-date rule.
    static let periodModifierPattern = #"(?:\d{4}\s*[년年]|\d{1,2}\s*[월月]|(?:다음|이번|지난|오는)\s*(?:주|달)|(?:내|작)년|(?:来|先|今|翌|次)(?:週|月|年)|\b(?:next|last|this|following|previous|coming)\s+(?:week|month|year)\b)"#
    static var nearestDateQualifierPattern: String {
        #"(?:"# + periodModifierPattern + #"|(?<![#\p{L}\d])\d{4}\b|\b"# + englishMonthNamePattern + #"\b)"#
    }
    static var clauseDateQualifierPattern: String {
        // English "may" can be a task word, and four-digit report IDs are
        // not years. Away from the date, require explicit period wording.
        #"(?:"# + periodModifierPattern + #"|\b(?:in|of|during|for)\s+(?:\d{4}\b|"#
            + englishMonthNamePattern + #"\b))"#
    }
    static func startsDateQualifier(_ text: String) -> Bool {
        !regexMatches(#"(?i)^\s*[,、（(\[]?\s*(?:(?:of|in)\s+)?"# + nearestDateQualifierPattern,in:text).isEmpty
    }

    static func beginsWrittenDate(_ text: String) -> Bool {
        let trimmed=text.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:",、")))
        let patterns=fullDatePatterns + partialDatePatterns + [#"(?i)^"# + englishMonthNamePattern + #"\.?\s+\d{1,2}(?:st|nd|rd|th)?\b"#]
        return patterns.contains { regexMatches($0,in:trimmed).contains {$0.range.location == 0} }
    }

    static func explicitDateMatches(
        in text: String,
        inferredYear: Int,
        inferenceReason: DateTimeReviewReason,
        timeZone: TimeZone
    ) -> [DateMatch] {
        var result: [DateMatch] = []
        let fullRanges = fullDatePatterns.flatMap { regexMatches($0,in:text).map(\.range) }
        for pattern in fullDatePatterns {
            for match in regexMatches(pattern, in: text) {
                guard
                    let year = integer(in: text, match: match, group: 1),
                    let month = integer(in: text, match: match, group: 2),
                    let day = integer(in: text, match: match, group: 3),
                    isValid(year: year, month: month, day: day, timeZone: timeZone)
                else { continue }
                result.append(DateMatch(
                    date: CalendarDate(year: year, month: month, day: day),
                    range: match.range,
                    reviewReasons: [],
                    hasExplicitYear: true
                ))
            }
        }

        for pattern in partialDatePatterns {
            for match in regexMatches(pattern, in: text) {
                // An invalid explicit year must never be replaced by an inferred year.
                guard !fullRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
                    continue
                }
                guard
                    let month = integer(in: text, match: match, group: 1),
                    let day = integer(in: text, match: match, group: 2),
                    isValid(year: inferredYear, month: month, day: day, timeZone: timeZone)
                else { continue }
                result.append(DateMatch(
                    date: CalendarDate(year: inferredYear, month: month, day: day),
                    range: match.range,
                    reviewReasons: [inferenceReason],
                    hasExplicitYear: false
                ))
            }
        }
        return result
    }

    static func relativeDateMatches(
        in text: String,
        basis: Date,
        analysisDate: Date,
        usedAnalysisDate: Bool,
        timeZone: TimeZone
    ) -> [DateMatch] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = calendar.startOfDay(for: basis)
        var result: [DateMatch] = []

        for (word, offset) in [("내일", 1), ("모레", 2)] {
            for match in regexMatches(word, in: text) {
                guard let resolved = calendar.date(byAdding: .day, value: offset, to: base) else {
                    continue
                }
                result.append(DateMatch(
                    date: calendarDate(from: resolved, calendar: calendar),
                    range: match.range,
                    reviewReasons: usedAnalysisDate
                        ? [.relativeDate, .relativeDateBasedOnAnalysisDate]
                        : [.relativeDate],
                    hasExplicitYear: true
                ))
            }
        }

        let currentDay = calendar.startOfDay(for: analysisDate)
        // Protect written dates even when invalid: they are not month-less deadlines.
        let explicitRanges = (fullDatePatterns + partialDatePatterns + [
            #"(?i)\b"# + englishMonthNamePattern + #"\.?\s+\d{1,2}(?:st|nd|rd|th)?\b"#
        ]).flatMap { regexMatches($0,in:text).map(\.range) }
        let weekdayAnnotationRanges = explicitRanges + dayOnlyPatterns.flatMap { regexMatches($0,in:text).map(\.range) }
        func isAnnotation(_ range: NSRange) -> Bool {
            weekdayAnnotationRanges.contains { dateRange in
                if NSIntersectionRange(dateRange, range).length > 0 { return true }
                let gap: NSRange
                if NSMaxRange(dateRange) <= range.location {
                    gap = NSRange(location:NSMaxRange(dateRange),length:range.location-NSMaxRange(dateRange))
                } else if NSMaxRange(range) <= dateRange.location {
                    gap = NSRange(location:NSMaxRange(range),length:dateRange.location-NSMaxRange(range))
                } else { return true }
                let between = (text as NSString).substring(with:gap)
                return between.allSatisfy { $0.isWhitespace || ",、()[]（）［］【】".contains($0) }
            }
        }
        func addWeekday(_ target: Int, range: NSRange, thisWeek: Bool = false) {
            guard !isAnnotation(range) else { return }
            let dateBasis = thisWeek ? base : currentDay
            let daysSinceMonday = (calendar.component(.weekday,from:dateBasis)+5)%7
            let offset = thisWeek ? target-daysSinceMonday : (target-daysSinceMonday+7)%7
            guard let resolved=calendar.date(byAdding:.day,value:offset,to:dateBasis) else { return }
            result.append(DateMatch(date:calendarDate(from:resolved,calendar:calendar),range:range,
                reviewReasons: !thisWeek || usedAnalysisDate ? [.relativeDate,.relativeDateBasedOnAnalysisDate]:[.relativeDate],hasExplicitYear:true))
        }
        // Calendar headers (including separate OCR cells) carry no task content.
        // Preserve existing deadline-only rows and explicit this-week behavior.
        let weekdayRanges = [koreanWeekdayPattern, englishWeekdayPattern, japaneseWeekdayPattern]
            .flatMap { regexMatches($0, in:text).map(\.range) }
        let headingRemainder = titleSuggestion(from:text, removing:weekdayRanges)
            .replacingOccurrences(of:#"(?i)\b(?:calendar|weekdays?|on|and)\b|달력|요일|カレンダー|曜日"#,with:"",options:.regularExpression)
            .replacingOccurrences(of:#"(?i)\b"# + englishMonthNamePattern + #"\b|\d+\s*[년年月월]"#,with:"",options:.regularExpression)
        let hasWeekdayContent = headingRemainder != "일정 확인 필요"
            && headingRemainder.range(of:#"\p{L}"#,options:.regularExpression) != nil
        func hasQualifier(_ range:NSRange) -> Bool {
            let prefix=(text as NSString).substring(to:range.location)
            let suffix=(text as NSString).substring(from:NSMaxRange(range))
            let before = #"(?i)(?:"# + nearestDateQualifierPattern
                + #"|\b(?:next|last|this|following|previous|coming))\s*(?:의|の)?\s*(?:on\s+)?[（(\[]?\s*$"#
            let outsideMatch=NSMutableString(string:text)
            outsideMatch.replaceCharacters(in:range,with:" ")
            // Modifiers can appear before/after the task words in this clause.
            // The matched Korean 이번 주 phrase retains its existing capture basis.
            return !regexMatches(before,in:prefix).isEmpty || startsDateQualifier(suffix)
                || !regexMatches(#"(?i)"# + clauseDateQualifierPattern,in:outsideMatch as String).isEmpty
        }
        let korean = ["월":0,"화":1,"수":2,"목":3,"금":4,"토":5,"일":6]
        for match in regexMatches(koreanWeekdayPattern,in:text) {
            guard let word=substring(in:text,range:match.range(at:1)),let target=korean[word],
                  !hasQualifier(match.range) else { continue }
            let matched=substring(in:text,range:match.range) ?? ""
            guard hasWeekdayContent || matched.contains("까지") || matched.hasPrefix("이번") else { continue }
            addWeekday(target,range:match.range,thisWeek:matched.hasPrefix("이번"))
        }
        let english = ["monday":0,"mon":0,"tuesday":1,"tue":1,"wednesday":2,"wed":2,"thursday":3,"thu":3,"friday":4,"fri":4,"saturday":5,"sat":5,"sunday":6,"sun":6]
        for match in regexMatches(englishWeekdayPattern,in:text) {
            guard let word=substring(in:text,range:match.range(at:1))?.lowercased(),let target=english[word],
                  !hasQualifier(match.range) else { continue }
            let suffix=(text as NSString).substring(from:NSMaxRange(match.range))
            let matched=(substring(in:text,range:match.range) ?? "").lowercased()
            guard !beginsWrittenDate(suffix),hasWeekdayContent || matched.hasPrefix("by ") || matched.hasPrefix("until ") else { continue }
            addWeekday(target,range:match.range)
        }
        let japanese = ["月":0,"火":1,"水":2,"木":3,"金":4,"土":5,"日":6]
        for match in regexMatches(japaneseWeekdayPattern,in:text) {
            guard let word=substring(in:text,range:match.range(at:1)),let target=japanese[word],
                  !hasQualifier(match.range) else { continue }
            guard hasWeekdayContent || (substring(in:text,range:match.range) ?? "").contains("まで") else { continue }
            addWeekday(target,range:match.range)
        }
        for pattern in dayOnlyPatterns {
            for match in regexMatches(pattern,in:text) {
                guard let day=integer(in:text,match:match,group:1),(1...31).contains(day),
                      !explicitRanges.contains(where:{NSIntersectionRange($0,match.range).length>0}),
                      !result.contains(where:{NSIntersectionRange($0.range,match.range).length>0}) else { continue }
                // An omitted range end inherits the written month in the existing range parser.
                // It must not also become an independent nearest-month day.
                let isWrittenRangeEnd = explicitRanges.contains { dateRange in
                    guard NSMaxRange(dateRange) <= match.range.location else { return false }
                    let gap=NSRange(location:NSMaxRange(dateRange),length:match.range.location-NSMaxRange(dateRange))
                    return !regexMatches(#"^\s*[~〜–—-]\s*$"#,in:(text as NSString).substring(with:gap)).isEmpty
                }
                guard !isWrittenRangeEnd else { continue }
                // Month/year qualifiers require their own interpretation, not this nearest-date fallback.
                let suffix=(text as NSString).substring(from:NSMaxRange(match.range))
                let prefix=(text as NSString).substring(to:match.range.location)
                let matched=substring(in:text,range:match.range) ?? ""
                let isEnglishOrdinal = !regexMatches(#"(?i)\d{1,2}(?:st|nd|rd|th)$"#,in:matched).isEmpty
                let hasDateMarker = !regexMatches(#"(?i)^(?:on|by|until)\s"#,in:matched).isEmpty
                let eventEdition = !regexMatches(#"(?i)^\s*(?:[\p{L}\p{N}'’()-]+\s+){0,8}(?:awards?|competitions?|contests?|festivals?|conferences?|congresses?|symposiums?)\b"#, in: suffix).isEmpty
                    && regexMatches(#"(?i)\b(?:deadline|due|submit|submission)\b"#, in: suffix).isEmpty
                let hasDeadlinePrefix = !regexMatches(#"(?i)\b(?:deadline|due)\s*(?:is\s*)?[:：]?\s*$"#, in: prefix).isEmpty
                let isOrdinalCounter = isEnglishOrdinal && !hasDateMarker && !hasDeadlinePrefix
                    && (eventEdition || !regexMatches(#"(?i)^\s*(?:draft|quarter|edition|round|place|prize|version|chapter|floor|anniversary|attempt|grade)\b"#,in:suffix).isEmpty)
                guard !isOrdinalCounter, !hasQualifier(match.range),
                      regexMatches(#"^\s*(?:동안|간|전|후|이전|이후|間|前|後)"#,in:suffix).isEmpty else { continue }
                let c=calendar.dateComponents([.year,.month],from:currentDay)
                guard let monthStart=calendar.date(from:DateComponents(year:c.year,month:c.month,day:1)) else { continue }
                for offset in 0...12 {
                    guard let month=calendar.date(byAdding:.month,value:offset,to:monthStart) else { continue }
                    let parts=calendar.dateComponents([.year,.month],from:month)
                    let candidate=CalendarDate(year:parts.year!,month:parts.month!,day:day)
                    guard candidate.isValidGregorianDate,let date=candidate.foundationDate(timeZone:timeZone),date>=currentDay else { continue }
                    result.append(DateMatch(date:candidate,range:match.range,reviewReasons:[.relativeDate,.relativeDateBasedOnAnalysisDate],hasExplicitYear:true))
                    break
                }
            }
        }
        return result
    }

    static func addOmittedRangeEndIfPresent(
        in text: String,
        matches: [DateMatch],
        timeZone: TimeZone
    ) -> [DateMatch] {
        var result = matches
        for first in matches {
            let suffixStart = NSMaxRange(first.range)
            let searchRange = NSRange(location: suffixStart, length: (text as NSString).length - suffixStart)
            guard let rangeMatch = firstRegexMatch(#"^\s*(?:~|〜|～|–|—|-)\s*(\d{1,2})일"#, in: text, range: searchRange) else {
                continue
            }
            guard
                let day = integer(in: text, match: rangeMatch, group: 1),
                isValid(
                    year: first.date.year,
                    month: first.date.month,
                    day: day,
                    timeZone: timeZone
                )
            else { continue }
            result.append(DateMatch(
                date: CalendarDate(year: first.date.year, month: first.date.month, day: day),
                range: rangeMatch.range(at: 1),
                reviewReasons: first.reviewReasons,
                hasExplicitYear: first.hasExplicitYear
            ))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static func applyRangeInheritance(
        in text: String,
        matches: [DateMatch],
        timeMatches: [TimeMatch],
        timeZoneResults: [TimeZoneResult]
    ) -> [DateMatch] {
        guard matches.count > 1 else { return matches }
        var result = matches
        for index in 0..<(result.count - 1) {
            guard isRangeSeparator(
                in: text,
                between: result[index].range,
                and: result[index + 1].range,
                timeMatches: timeMatches,
                timeZoneResults: timeZoneResults
            ) else {
                continue
            }
            if result[index].hasExplicitYear, !result[index + 1].hasExplicitYear {
                let next = result[index + 1].date
                result[index + 1].date = CalendarDate(
                    year: result[index].date.year,
                    month: next.month,
                    day: next.day
                )
                result[index + 1].reviewReasons.removeAll {
                    $0 == .yearInferredFromCaptureDate || $0 == .yearInferredFromAnalysisDate
                }
            }
            if dateSortValue(result[index + 1].date) < dateSortValue(result[index].date) {
                result[index + 1].reviewReasons.append(.ambiguousRange)
            }
        }
        return result
    }

    static func timeMatches(in text: String) -> [TimeMatch] {
        var result: [TimeMatch] = []
        let clockPattern = #"(?i)(?<!\d)(?:(?<!\p{L})(AM|PM|A\.M\.|P\.M\.|오전|오후)\s*)?([01]?\d|2[0-3]):([0-5]\d)(?:\s*(AM|PM|A\.M\.|P\.M\.|오전|오후)(?!\p{L}))?(?!\d)"#
        for match in regexMatches(clockPattern, in: text) {
            guard
                let rawHour = integer(in: text, match: match, group: 2),
                let minute = integer(in: text, match: match, group: 3)
            else { continue }
            let prefix = substring(in: text, range: match.range(at: 1))
            let suffix = substring(in: text, range: match.range(at: 4))
            let marker = prefix ?? suffix
            if marker != nil, !(1...12).contains(rawHour) { continue }
            if let prefix, let suffix, isPM(prefix) != isPM(suffix) { continue }
            let hour = marker.map { rawHour % 12 + (isPM($0) ? 12 : 0) } ?? rawHour
            result.append(TimeMatch(
                time: ClockTime(hour: hour, minute: minute),
                range: match.range
            ))
        }
        for match in regexMatches(#"(오전|오후)\s*(\d{1,2})시(?:\s*(\d{1,2})분)?"#, in: text) {
            guard
                let meridiem = substring(in: text, range: match.range(at: 1)),
                let rawHour = integer(in: text, match: match, group: 2),
                (1...12).contains(rawHour)
            else { continue }
            let minute = integer(in: text, match: match, group: 3) ?? 0
            guard (0...59).contains(minute) else { continue }
            let hour = meridiem == "오후"
                ? (rawHour == 12 ? 12 : rawHour + 12)
                : (rawHour == 12 ? 0 : rawHour)
            result.append(TimeMatch(
                time: ClockTime(hour: hour, minute: minute),
                range: match.range
            ))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static func rangeRoles(
        in text: String,
        dateMatches: [DateMatch],
        timeMatches: [TimeMatch],
        timeZoneResults: [TimeZoneResult]
    ) -> [DateTimeRangeRole] {
        var roles = Array(repeating: DateTimeRangeRole.standalone, count: dateMatches.count)
        guard dateMatches.count > 1 else { return roles }
        for index in 0..<(dateMatches.count - 1)
        where isRangeSeparator(
            in: text,
            between: dateMatches[index].range,
            and: dateMatches[index + 1].range,
            timeMatches: timeMatches,
            timeZoneResults: timeZoneResults
        ) {
            roles[index] = .start
            roles[index + 1] = .end
        }
        return roles
    }

    static func isRangeSeparator(
        in text: String,
        between left: NSRange,
        and right: NSRange,
        timeMatches: [TimeMatch],
        timeZoneResults: [TimeZoneResult]
    ) -> Bool {
        let leftTimeIndex = timeMatches.indices.last {
            timeMatches[$0].range.location >= NSMaxRange(left)
                && NSMaxRange(timeMatches[$0].range) <= right.location
        }
        let start: Int
        if let leftTimeIndex {
            let timeEnd = NSMaxRange(timeMatches[leftTimeIndex].range)
            if let zoneRange = timeZoneResults[leftTimeIndex].range,
               zoneRange.location >= timeEnd,
               NSMaxRange(zoneRange) <= right.location {
                start = NSMaxRange(zoneRange)
            } else {
                start = timeEnd
            }
        } else {
            start = NSMaxRange(left)
        }
        guard right.location >= start else { return false }
        let range = NSRange(location: start, length: right.location - start)
        guard let separator = substring(in: text, range: range) else { return false }
        return separator.range(of: #"^\s*(?:~|〜|～|–|—|-)\s*$"#, options: .regularExpression) != nil
    }

    struct TimeAssignments {
        var byDate: [Int: Int] = [:]
        var uncertainDates: Set<Int> = []
        var rangeDates: Set<Int> = []
    }

    static func assignTimes(
        in text: String,
        dateMatches: [DateMatch],
        timeMatches: [TimeMatch],
        timeZoneResults: [TimeZoneResult]
    ) -> TimeAssignments {
        var result = TimeAssignments()
        guard !dateMatches.isEmpty, !timeMatches.isEmpty else { return result }
        // Each date owns only its local interval up to the next written date.
        // A consumed date is never revisited to take a later unpaired time.
        let following = dateMatches.indices.map { dateIndex in
            timeMatches.indices.filter { timeIndex in
                timeMatches[timeIndex].range.location >= NSMaxRange(dateMatches[dateIndex].range)
                    && (dateIndex + 1 == dateMatches.count
                        || NSMaxRange(timeMatches[timeIndex].range) <= dateMatches[dateIndex + 1].range.location)
            }
        }
        let leading = timeMatches.indices.filter {
            NSMaxRange(timeMatches[$0].range) <= dateMatches[0].range.location
        }
        // "D D T T" (or "T T D D") is a list, not evidence of pairing.
        // A recognized date-range boundary retains the existing end-only-time contract.
        var groupStart = 0
        for index in dateMatches.indices {
            let connectsNext = index + 1 < dateMatches.count && following[index].isEmpty
                && !isRangeSeparator(in:text,between:dateMatches[index].range,and:dateMatches[index + 1].range,
                                     timeMatches:timeMatches,timeZoneResults:timeZoneResults)
            if connectsNext { continue }
            if index > groupStart, !following[index].isEmpty || (groupStart == 0 && !leading.isEmpty) {
                result.uncertainDates.formUnion(groupStart...index)
            }
            groupStart = index + 1
        }
        for dateIndex in dateMatches.indices where !result.uncertainDates.contains(dateIndex) {
            let times = following[dateIndex]
            if dateIndex == 0, !leading.isEmpty {
                if leading.count == 1, times.isEmpty, let first = leading.first {
                    let gap = NSRange(location:NSMaxRange(timeMatches[first].range),
                                      length:dateMatches[0].range.location - NSMaxRange(timeMatches[first].range))
                    if substring(in:text,range:gap)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == true {
                        result.byDate[dateIndex] = first
                    } else {
                        result.uncertainDates.insert(dateIndex)
                    }
                } else {
                    result.uncertainDates.insert(dateIndex)
                }
                continue
            }
            if times.count == 1 {
                result.byDate[dateIndex] = times[0]
            } else if times.count > 1 {
                // Keep one stored time for a clearly written range, but require
                // explicit acknowledgement that its end/duration cannot be saved.
                let startRange = timeZoneResults[times[0]].range.map {
                    NSUnionRange(timeMatches[times[0]].range, $0)
                } ?? timeMatches[times[0]].range
                let isTimeRange = times.count == 2 && isRangeSeparator(
                    in:text,between:startRange,and:timeMatches[times[1]].range,
                    timeMatches:[],timeZoneResults:[])
                if isTimeRange {
                    result.byDate[dateIndex] = times[0]
                    result.rangeDates.insert(dateIndex)
                } else {
                    result.uncertainDates.insert(dateIndex)
                }
            }
        }
        // Unresolved clocks immediately before a following date can also belong
        // to that date. Do not leave it ready as an all-day event. The acknowledged
        // end of a recognized time range is not an unowned clock.
        for dateIndex in dateMatches.indices where result.uncertainDates.contains(dateIndex)
            && !result.rangeDates.contains(dateIndex) && dateIndex + 1 < dateMatches.count {
            guard let lastTime = following[dateIndex].last else { continue }
            let end = timeZoneResults[lastTime].range.map(NSMaxRange) ?? NSMaxRange(timeMatches[lastTime].range)
            guard end <= dateMatches[dateIndex + 1].range.location else { continue }
            let gap = NSRange(location: end, length: dateMatches[dateIndex + 1].range.location - end)
            guard substring(in: text, range: gap)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else { continue }
            result.uncertainDates.insert(dateIndex + 1)
        }
        // The affected next date may itself be followed by an undifferentiated
        // date list. Preserve the same uncertainty across that list only.
        groupStart = 0
        for index in dateMatches.indices {
            let connectsNext = index + 1 < dateMatches.count && following[index].isEmpty
                && !isRangeSeparator(in:text,between:dateMatches[index].range,and:dateMatches[index + 1].range,
                                     timeMatches:timeMatches,timeZoneResults:timeZoneResults)
            if connectsNext { continue }
            if !(result.uncertainDates.intersection(Set(groupStart...index))).isEmpty {
                result.uncertainDates.formUnion(groupStart...index)
            }
            groupStart = index + 1
        }
        for index in result.uncertainDates { result.byDate[index] = nil }
        return result
    }

    static func explicitTimeZone(in text: String, after timeRange: NSRange?) -> TimeZoneResult {
        guard let timeRange else {
            return TimeZoneResult(identifier: nil, range: nil, isUnsupported: false)
        }
        let start = NSMaxRange(timeRange)
        let nsText = text as NSString
        guard start <= nsText.length else {
            return TimeZoneResult(identifier: nil, range: nil, isUnsupported: false)
        }
        let searchRange = NSRange(location: start, length: nsText.length - start)
        let mappings = ["KST": "Asia/Seoul", "UTC": "UTC", "GMT": "GMT"]
        if let match = firstRegexMatch(#"^\s+(KST|UTC|GMT)\b"#, in: text, range: searchRange),
           let token = substring(in: text, range: match.range(at: 1)),
           let identifier = mappings[token] {
            return TimeZoneResult(
                identifier: identifier,
                range: match.range,
                isUnsupported: false
            )
        }

        guard let match = firstRegexMatch(
            #"^\s+(?:TZ|시간대)\s*[:=]\s*([A-Za-z][A-Za-z0-9_+\-/]{1,63})\b"#,
            in: text,
            range: searchRange
        ), let token = substring(in: text, range: match.range(at: 1)) else {
            return TimeZoneResult(identifier: nil, range: nil, isUnsupported: false)
        }
        if let identifier = mappings[token] {
            return TimeZoneResult(identifier: identifier, range: match.range, isUnsupported: false)
        }
        if let zone = TimeZone(identifier: token) ?? TimeZone(abbreviation: token) {
            return TimeZoneResult(
                identifier: zone.identifier,
                range: match.range,
                isUnsupported: false
            )
        }
        return TimeZoneResult(identifier: nil, range: match.range, isUnsupported: true)
    }

    static func isStandaloneStatusBarTime(
        text: String,
        timeRange: NSRange,
        boundingBox: CGRect
    ) -> Bool {
        let remainder = titleSuggestion(from: text, removing: [timeRange])
        return remainder == "일정 확인 필요"
            && boundingBox.maxY >= 0.94
            && boundingBox.height <= 0.06
    }

    static func titleSuggestion(from text: String, removing ranges: [NSRange]) -> String {
        let mutable = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location })
        where range.location != NSNotFound && NSMaxRange(range) <= mutable.length {
            mutable.replaceCharacters(in: range, with: " ")
        }
        let cleaned = (mutable as String)
            .replacingOccurrences(of: #"[~〜～–—|,:·]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !isFormLabel(cleaned) else { return "일정 확인 필요" }
        return String(cleaned.prefix(60))
    }

    static func looksLikeVersion(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(?:^|\s)(?:v|version|버전)\s*\d{4}[./-]\d{1,2}[./-]\d{1,2}"#,
            options: .regularExpression
        ) != nil
    }

    static func isValid(
        year: Int,
        month: Int,
        day: Int,
        timeZone: TimeZone
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    static func components(of date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func calendarDate(from date: Date, calendar: Calendar) -> CalendarDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    static func dateSortValue(_ date: CalendarDate) -> Int {
        date.year * 10_000 + date.month * 100 + date.day
    }

    static func trimmingWhitespace(in text: NSString, range: NSRange) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines
        while lower < upper,
              let scalar = UnicodeScalar(text.character(at: lower)),
              whitespace.contains(scalar) {
            lower += 1
        }
        while upper > lower,
              let scalar = UnicodeScalar(text.character(at: upper - 1)),
              whitespace.contains(scalar) {
            upper -= 1
        }
        return NSRange(location: lower, length: upper - lower)
    }

    static func regexMatches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    static func firstRegexMatch(
        _ pattern: String,
        in text: String,
        range: NSRange
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: range)
    }

    static func integer(
        in text: String,
        match: NSTextCheckingResult,
        group: Int
    ) -> Int? {
        guard let value = substring(in: text, range: match.range(at: group)) else { return nil }
        return Int(value)
    }

    static func substring(in text: String, range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
