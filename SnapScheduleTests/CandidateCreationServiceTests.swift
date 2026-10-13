import SwiftData
import XCTest
@testable import SnapSchedule

@MainActor
final class CandidateCreationServiceTests: XCTestCase {
    func testRealParserMultipleDatesCanFillOneCandidatesAddedRowWithoutInventingTime() throws {
        let h = try makeHarness(assetIdentifiers: ["add-parsed-date"])
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let fragments = [RecognizedTextFragment(text: "Meeting 2026-10-18 2026-10-20",
            boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.05), confidence: 1)]
        let parsed = DateTimeParser().parse(fragments: fragments, captureDate: nil,
            analysisDate: Date(timeIntervalSince1970: 1791334800), timeZone: TimeZone(identifier: "Asia/Seoul")!)
        let ids = try h.service.completeAnalysis(scan, owner: h.owner, drafts: parsed, fragments: fragments,
            settings: h.settings, analysisVersion: "vision3-parser2-filter1")
        XCTAssertEqual(ids.count, 1)
        let source = try XCTUnwrap(try fetchCandidates(h.context).first)
        XCTAssertEqual(source.recognizedDateOptions.count, 2)
        var draft = CandidateDetailDraft(candidate: source)
        XCTAssertEqual(draft.dateEntries.count, 1)
        XCTAssertEqual(draft.date, CalendarDate(year: 2026, month: 10, day: 18))
        draft.addDate()
        XCTAssertEqual(draft.dateEntries[1].date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertNil(draft.dateEntries[1].time)
        XCTAssertTrue(draft.remainingReviewReasons.contains(.ambiguousDate))
        XCTAssertFalse(draft.isRegistrationEligible)
        XCTAssertEqual(try fetchCandidates(h.context).count, 1)
    }

    func testChoosingRecognizedDatePreservesUncertainTimeReviewThroughReopen() throws {
        let h = try makeHarness(assetIdentifiers: ["option-warning"])
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let fragments = [RecognizedTextFragment(text: "Meeting 2026-10-18 2026-10-20 09:00 14:00",
            boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.05), confidence: 1)]
        let parsed = DateTimeParser().parse(fragments: fragments, captureDate: nil,
            analysisDate: Date(timeIntervalSince1970: 1791334800), timeZone: TimeZone(identifier: "Asia/Seoul")!)
        _ = try h.service.completeAnalysis(scan, owner: h.owner, drafts: parsed, fragments: fragments,
            settings: h.settings, analysisVersion: "vision3-parser2-filter1")
        let source = try XCTUnwrap(try fetchCandidates(h.context).first)
        XCTAssertEqual(source.recognizedDateOptions.count, 2)
        var draft = CandidateDetailDraft(candidate: source)
        var selected = source.recognizedDateOptions[1]; selected.id = draft.dateEntries[0].id
        draft.dateEntries[0] = CandidateDateDraft(entry: selected)
        try draft.saveUnregistered(to: source, in: h.context)
        let reopened = ModelContext(h.context.container)
        let restoredSource = try XCTUnwrap(try reopened.fetch(FetchDescriptor<ScheduleCandidate>()).first)
        var restored = CandidateDetailDraft(candidate: restoredSource)
        XCTAssertTrue(restored.remainingReviewReasons.contains(.uncertainTimeAssociation))
        XCTAssertFalse(restored.isRegistrationEligible); XCTAssertNil(restored.time)
        restored.confirmedReviewReasons.insert(.uncertainTimeAssociation)
        _ = try restored.register(to: restoredSource, in: reopened, service: ScheduleRegistrationService(context: reopened, widgetSnapshotRefresh: {}))
        let schedule = try XCTUnwrap(try reopened.fetch(FetchDescriptor<Schedule>()).first)
        XCTAssertEqual(schedule.date, CalendarDate(year: 2026, month: 10, day: 20))
        XCTAssertNil(schedule.time)
    }
    func testNewPhotoWithSeveralDatesCreatesOneReviewCandidate() throws {
        let h = try makeHarness(assetIdentifiers: ["photo-batch"])
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let input = [draft(key: "first", title: "Meeting", evidence: "First date"), draft(key: "second", title: "Meeting", evidence: "Second date",
            date: CalendarDate(year: 2026, month: 10, day: 20))]
        let ids = try h.service.completeAnalysis(scan, owner: h.owner, drafts: input,
            settings: h.settings, analysisVersion: "vision3-parser2-filter1")
        XCTAssertEqual(ids.count, 1, "One photo must have one candidate even with several dates")
        let candidates = try fetchCandidates(h.context)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates.first!.isRegistrationEligible, "Several dates require a choice inside the candidate")
    }
    // Real parser -> creation -> selection -> editor -> registration boundary.
    func testUncertainTimeCandidatesCannotDefaultSelectOrRegisterBeforeConfirmation() throws {
        for (index,text) in ["회의 2026-10-08 2026-10-09 09:00 14:00", "Meeting 2026-10-08 2026-10-09 09:00 14:00", "会議 2026-10-08 2026-10-09 09:00 14:00", "회의 2026-10-08 09:00~18:00", "Meeting 2026-10-08 09:00~18:00", "会議 2026-10-08 09:00〜18:00"].enumerated() {
            let h=try makeHarness(assetIdentifiers:["time-review-\(index)"])
            let scan=try XCTUnwrap(h.queue.claimNext(owner:h.owner))
            let fragments=[RecognizedTextFragment(text:text,boundingBox:CGRect(x:0.1,y:0.6,width:0.8,height:0.04),confidence:1)]
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:nil,analysisDate:Date(timeIntervalSince1970:1791334800),timeZone:TimeZone(identifier:"Asia/Seoul")!)
            let ids=try h.service.completeAnalysis(scan,owner:h.owner,drafts:drafts,fragments:fragments,settings:h.settings,analysisVersion:"vision3-parser2-filter1")
            XCTAssertEqual(ids.count,1)
            let candidates=try fetchCandidates(h.context)
            let selection=CandidateSelectionState();selection.synchronize(with:candidates)
            XCTAssertTrue(selection.selectedCandidateIDs.isEmpty)
            XCTAssertEqual(CandidateReviewSummary(candidates:candidates).readyCount,0)
            let registration=ScheduleRegistrationService(context:h.context,widgetSnapshotRefresh:{})
            for (processed,candidate) in candidates.enumerated() {
                XCTAssertFalse(candidate.isRegistrationEligible)
                XCTAssertTrue(candidate.reviewReasons.map(\.rawValue).contains(index < 3 ? "uncertainTimeAssociation":"timeRangeNotStored"))
                var edit=CandidateDetailDraft(candidate:candidate)
                if index < 3 {XCTAssertNil(edit.time)} else {XCTAssertEqual(edit.time,ClockTime(hour:9,minute:0))}
                // Date-only is a deliberate user choice, not automatic dismissal of the warning.
                edit.time=nil
                XCTAssertFalse(edit.isRegistrationEligible)
                try edit.saveUnregistered(to:candidate,in:h.context)
                XCTAssertFalse(CandidateDetailDraft(candidate:candidate).isRegistrationEligible)
                XCTAssertThrowsError(try registration.register(candidateIDs:[candidate.id]))
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()),processed)
                edit.confirmedReviewReasons=Set(candidate.reviewReasons)
                if index >= 3 {edit.confirmedReviewReasons.insert(.timeZoneInferred)}
                if index >= 3 {edit.time=ClockTime(hour:10,minute:30);edit.timeZoneIdentifier="Asia/Seoul"}
                try edit.save(to:candidate,in:h.context)
                _=try registration.register(candidateIDs:[candidate.id])
                let saved=try XCTUnwrap(try h.context.fetch(FetchDescriptor<Schedule>()).first {$0.sourceCandidateID == candidate.id})
                XCTAssertEqual(saved.date,candidate.date)
                XCTAssertEqual(saved.time,index < 3 ? nil:ClockTime(hour:10,minute:30))
                XCTAssertEqual(candidate.evidenceText,text)
            }
        }
    }

    func testShortReviewTabsOnlyIdentifyCurrentHomeWithBrandedCalendar() throws {
        for (index, labels) in [["Review", "Home", "Settings", "SnapSchedule calendar"], ["予定確認", "ホーム", "設定", "SnapScheduleのカレンダー"], ["Review", "Home", "Settings", "ShotToSchedule calendar"], ["予定確認", "ホーム", "設定", "ショットスケジュールのカレンダー"]].enumerated() {
            for branded in [true, false] {
                let h = try makeHarness(assetIdentifiers: ["short-tabs-\(index)-\(branded)"])
                let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
                let texts = Array(labels.prefix(3)) + [branded ? labels[3] : (index == 0 ? "Calendar" : "カレンダー"), "Meeting 2026-10-08"]
                let fragments = texts.enumerated().map { RecognizedTextFragment(text: $0.element, boundingBox: CGRect(x: 0.1, y: 0.1 + Double($0.offset) * 0.1, width: 0.8, height: 0.03), confidence: 0.99) }
                let drafts = DateTimeParser().parse(fragments: fragments, captureDate: nil, analysisDate: Date(timeIntervalSince1970: 1791334800), timeZone: TimeZone(identifier: "Asia/Seoul")!)
                let ids = try h.service.completeAnalysis(scan, owner: h.owner, drafts: drafts, fragments: fragments, settings: h.settings, analysisVersion: "vision3-parser2-filter1")
                XCTAssertEqual(ids.count, branded ? 0 : 1, "Short labels require the SnapSchedule calendar anchor")
            }
        }
    }

    func testDatePolicyKeepsBusinessReservationDeadlineVoucherMemoAndUncertainMetadata() throws {
        let cases:[(String,Bool)] = [
            ("보고서 보내주세요 2026-10-08",false),("Please send the report 2026-10-08",false),("報告書を送ってください 2026-10-08",false),
            ("예약 안내 2026-10-08",false),("Reservation 2026-10-08",false),("予約案内 2026-10-08",false),
            ("신청 마감 2026-10-08",false),("Apply by 2026-10-08",false),("申込締切 2026-10-08",false),
            ("기프티콘 유효기간 2026-10-08",false),("Voucher valid until 2026-10-08",false),("ギフト券の有効期限 2026-10-08",false),
            ("2026-10-08",true),("날짜: 2026-10-08",true),("Date: 2026-10-08",true),("日付: 2026-10-08",true),
            ("작성일: 2026-10-08 09:00 KST",true),("Published: 2026-10-08 09:00 KST",true),("投稿日: 2026-10-08 09:00 KST",true),
            ("메모 작성 시각: 2026-10-08 09:00 KST",true),("Created: 2026-10-08 09:00 KST",true),("作成日時: 2026-10-08 09:00 KST",true),
            ("달력 2026-10-08",true),("Calendar 2026-10-08",true),("カレンダー 2026-10-08",true),
            ("작성일: 2026-10-08 09:00 KST 작성자 홍길동",true),("Published: 2026-10-08 09:00 KST by Alice",true),("投稿日: 2026-10-08 09:00 KST 投稿者 山田",true),
            ("Published book launch 2026-10-08",false),
            ("파란 우산 2026-10-08",false),("Blue umbrella 2026-10-08",false),("青い傘 2026-10-08",false)
        ]
        for (i,item) in cases.enumerated() {
            let (text,review)=item
            let h=try makeHarness(assetIdentifiers:["date-policy-\(i)"])
            let scan=try XCTUnwrap(h.queue.claimNext(owner:h.owner))
            let fragments=[RecognizedTextFragment(text:text,boundingBox:CGRect(x:0.1,y:0.6,width:0.8,height:0.04),confidence:1)]
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:nil,analysisDate:Date(timeIntervalSince1970:1791334800),timeZone:TimeZone(identifier:"Asia/Seoul")!)
            let ids=try h.service.completeAnalysis(scan,owner:h.owner,drafts:drafts,fragments:fragments,settings:h.settings,analysisVersion:"vision3-parser2-filter1")
            XCTAssertEqual(ids.count,1,text)
            let c=try XCTUnwrap(try fetchCandidates(h.context).first)
            XCTAssertEqual(c.date,CalendarDate(year:2026,month:10,day:8),text)
            XCTAssertEqual(c.requiresReview,review,text)
            XCTAssertEqual(c.isSelectedByDefault,!review,text)
            XCTAssertEqual(c.isRegistrationEligible,!review,text)
            XCTAssertEqual(c.evidenceText,text)
            if !text.contains("09:00") {XCTAssertNil(c.time);XCTAssertNil(c.timeZoneIdentifier)}
        }
    }

    func testPlainBusinessDateCandidatesRequireConfirmationBeforeRegistration() throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Seoul")!
        let now=try XCTUnwrap(calendar.date(from:DateComponents(year:2026,month:10,day:7,hour:12)))
        let texts=["수요일 보고서 제출","Submit the report Wednesday","水曜日に報告書を提出",
                   "8일 보고서 제출","Submit the report on the 8th","8日に報告書を提出"]
        for (i,text) in texts.enumerated() {
            let h=try makeHarness(assetIdentifiers:["plain-business-\(i)"])
            let scan=try XCTUnwrap(h.queue.claimNext(owner:h.owner))
            let fragments=[RecognizedTextFragment(text:text,boundingBox:CGRect(x:0.1,y:0.6,width:0.8,height:0.04),confidence:1)]
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:nil,analysisDate:now,timeZone:calendar.timeZone)
            let ids=try h.service.completeAnalysis(scan,owner:h.owner,drafts:drafts,fragments:fragments,settings:h.settings,analysisVersion:"unchanged")
            XCTAssertEqual(ids.count,1,text)
            let candidate=try XCTUnwrap(try fetchCandidates(h.context).first)
            XCTAssertEqual(candidate.date,CalendarDate(year:2026,month:10,day:i < 3 ? 7:8))
            XCTAssertNil(candidate.time);XCTAssertNil(candidate.timeZoneIdentifier)
            XCTAssertEqual(candidate.reviewReasons,[.relativeDate,.relativeDateBasedOnAnalysisDate])
            XCTAssertFalse(candidate.isRegistrationEligible)
            let registration=ScheduleRegistrationService(context:h.context,widgetSnapshotRefresh:{})
            XCTAssertThrowsError(try registration.register(candidateIDs:Set(ids)),text)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()),0)
            var editor=CandidateDetailDraft(candidate:candidate)
            editor.confirmedReviewReasons=Set(candidate.reviewReasons)
            try editor.save(to:candidate,in:h.context)
            XCTAssertTrue(candidate.isRegistrationEligible)
            _=try registration.register(candidateIDs:Set(ids))
            let saved=try XCTUnwrap(try h.context.fetch(FetchDescriptor<Schedule>()).first)
            XCTAssertEqual(saved.title,drafts.first?.titleSuggestion);XCTAssertEqual(saved.date,candidate.date)
            XCTAssertNil(saved.time);XCTAssertEqual(saved.timeZoneIdentifier,TimeZone.current.identifier)
        }
    }

    func testTabHomeScreensAreExcludedWithStrongLabelsOnlyInAllLanguages() throws {
        for (index, labels) in [
            ["Candidate review", "Home", "Settings", "Calendar", "1 registered schedules · Registration order"],
            ["후보 검수", "홈", "설정", "캘린더", "등록 일정 1개 · 등록순"],
            ["候補の確認", "ホーム", "設定", "カレンダー", "登録済みの予定1件 · 登録順"],
            ["Review schedules", "Home", "Settings", "SnapSchedule calendar", "1 registered schedules · Registration order"],
            ["일정 확인", "홈", "설정", "SnapSchedule 달력", "등록 일정 1개 · 등록순"],
            ["予定を確認", "ホーム", "設定", "SnapScheduleのカレンダー", "登録済みの予定1件 · 登録順"],
            ["Review schedules", "Home", "Settings", "ShotToSchedule calendar", "1 registered schedules · Registration order"],
            ["일정 확인", "홈", "설정", "샷스케줄 달력", "등록 일정 1개 · 등록순"],
            ["予定を確認", "ホーム", "設定", "ショットスケジュールのカレンダー", "登録済みの予定1件 · 登録順"],
            ["Original Screenshot", "Also add to Apple Calendar after registration", "Notify one day before", "Notify on the day", "Review schedule"],
            ["원본 스크린샷", "등록 후 Apple 캘린더에도 추가", "하루 전 알림", "당일 알림", "일정 확인"],
            ["元のスクリーンショット", "登録後にAppleカレンダーにも追加", "前日に通知", "当日に通知", "予定を確認"],
            ["Apple Calendar copy", "Original Screenshot", "Delete Schedule", "Title"],
            ["Apple 캘린더 사본", "원본 스크린샷", "일정 삭제", "제목"],
            ["Appleカレンダーのコピー", "元のスクリーンショット", "予定を削除", "タイトル"]
        ].enumerated() {
            for (variant, confidence, texts, excluded) in [
                ("app", Float(0.99), labels, true),
                ("compact", Float(0.99), Array(labels.prefix(4)), true),
                ("weak", Float(0.6), labels, false),
                ("external", Float(0.99), labels.map { "Guide: " + $0 }, false),
                ("missing", Float(0.99), Array(labels.dropFirst()), false)
            ] {
                let h = try makeHarness(assetIdentifiers: ["tabs-\(index)-\(variant)"])
                let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
                let ids = try h.service.completeAnalysis(scan, owner: h.owner,
                    drafts: [draft(key: "event", title: "Event", evidence: "2026-10-07 Event")],
                    fragments: texts.map { RecognizedTextFragment(text: $0,
                        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1), confidence: confidence) },
                    settings: h.settings, analysisVersion: "unchanged")
                XCTAssertEqual(ids.isEmpty, excluded, "\(index) \(variant)")
            }
        }
    }
    func testNotesMetadataAndCroppedEditorReproduction() throws {
        func fragment(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> RecognizedTextFragment {
            RecognizedTextFragment(text: text, boundingBox: CGRect(x:x,y:y,width:w,height:h), confidence:0.99)
        }
        let notes = [
            fragment("2026년 10월 4일 오전 2:54",0.273,0.874,0.376,0.017),
            fragment("Task38 잔여 검증",0.059,0.830,0.449,0.032),
            fragment("2026년 10월 6일 오후 4시",0.059,0.795,0.395,0.022),
            fragment("장소: 테스트룸",0.059,0.768,0.215,0.023),
            fragment("가가",0.049,0.402,0.117,0.025),
            fragment("123",0.029,0.108,0.073,0.020)
        ]
        let app = [
            fragment("직접 입력",0.10,0.80,0.16,0.025),
            fragment("인식 근거",0.10,0.43,0.18,0.020),
            fragment("2026년 10월 4일 오전 2:54",0.10,0.40,0.45,0.022),
            fragment("추정한 시간대 확인",0.10,0.35,0.30,0.025),
            fragment("하루 전 알림",0.10,0.18,0.22,0.025),
            fragment("당일 알림",0.10,0.12,0.18,0.025),
            fragment("후보 검수",0.28,0.04,0.18,0.025),
            fragment("홈",0.55,0.04,0.07,0.025),
            fragment("설정",0.78,0.04,0.10,0.025)
        ]
        for (index, fragments, expected) in [(0,notes,1),(1,app,0)] {
            let h = try makeHarness(assetIdentifiers:["residual-\(index)"])
            let scan = try XCTUnwrap(h.queue.claimNext(owner:h.owner))
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:Date(timeIntervalSince1970:1791064800),analysisDate:Date(timeIntervalSince1970:1791334800),timeZone:TimeZone(identifier:"US/Pacific")!)
            let ids=try h.service.completeAnalysis(scan,owner:h.owner,drafts:drafts,fragments:fragments,settings:h.settings,analysisVersion:"unchanged")
            XCTAssertEqual(ids.count,expected,"\(index): unwanted metadata/editor date must not become a new schedule")
            if index == 0 {
                let kept=try XCTUnwrap(try h.context.fetch(FetchDescriptor<ScheduleCandidate>()).first)
                XCTAssertEqual(kept.date,CalendarDate(year:2026,month:10,day:6))
                XCTAssertEqual(kept.time,ClockTime(hour:16,minute:0))
                XCTAssertTrue(kept.evidenceText?.contains("테스트룸") == true)
            }
        }
    }

    func testCroppedEditorRulePreservesWeakMissingQuotedAndMisplacedLabelsInThreeLanguages() throws {
        let labels = [
            ["Enter your own title","Evidence","Confirm the inferred time zone","Notify one day before","Notify on the day","Review schedules","Home","Settings"],
            ["직접 입력","인식 근거","추정한 시간대 확인","하루 전 알림","당일 알림","일정 확인","홈","설정"],
            ["直接入力","認識の根拠","推定されたタイムゾーンを確認","前日に通知","当日に通知","予定を確認","ホーム","設定"]
        ]
        let boxes = [CGRect(x:0.1,y:0.8,width:0.4,height:0.025),CGRect(x:0.1,y:0.43,width:0.4,height:0.02),
            CGRect(x:0.1,y:0.35,width:0.4,height:0.025),CGRect(x:0.1,y:0.18,width:0.4,height:0.025),
            CGRect(x:0.1,y:0.12,width:0.4,height:0.025),CGRect(x:0.05,y:0.04,width:0.25,height:0.025),
            CGRect(x:0.45,y:0.04,width:0.1,height:0.025),CGRect(x:0.7,y:0.04,width:0.2,height:0.025)]
        for (language,texts) in labels.enumerated() {
            let date=RecognizedTextFragment(text:"2026-10-04 02:54",boundingBox:CGRect(x:0.1,y:0.4,width:0.4,height:0.02),confidence:1)
            let clear=zip(texts,boxes).map { RecognizedTextFragment(text:$0.0,boundingBox:$0.1,confidence:0.5) }+[date]
            let variants: [(String,[RecognizedTextFragment],Int)] = [
                ("clear",clear,0),
                ("weak",clear.map { RecognizedTextFragment(text:$0.text,boundingBox:$0.boundingBox,confidence:0.49) },1),
                ("quote",clear.map { RecognizedTextFragment(text:"Guide: "+$0.text,boundingBox:$0.boundingBox,confidence:1) },1),
                ("unordered",clear.map { RecognizedTextFragment(text:$0.text,boundingBox:CGRect(x:0.1,y:0.4,width:0.4,height:0.02),confidence:1) },1)
            ]
            // Every missing clue must preserve the event; build omissions explicitly.
            let omissions=clear.indices.map { index in ("omission-\(index)",clear.enumerated().filter {$0.offset != index}.map(\.element),1) }
            for (variant,fragments,count) in variants+omissions {
                let h=try makeHarness(assetIdentifiers:["editor-\(language)-\(variant)"])
                let scan=try XCTUnwrap(h.queue.claimNext(owner:h.owner))
                let ids=try h.service.completeAnalysis(scan,owner:h.owner,drafts:[draft(key:"external-event",title:"Meeting",evidence:date.text)],fragments:fragments,settings:h.settings,analysisVersion:"unchanged")
                XCTAssertEqual(ids.count,count,"\(language) \(variant)")
            }
        }
    }

    func testNewExclusionDoesNotReanalyzeOrChangeExistingTwoSourceThreePendingSchedules() throws {
        let h=try makeHarness(assetIdentifiers:["new-app"])
        let existing=(0..<3).map { index in ScheduleCandidate(sourceAssetIdentifier:index == 1 ? "old-app":"old-notes",
            sourceCandidateKey:"old-\(index)",evidenceText:"old evidence",title:"old title \(index)",
            date:CalendarDate(year:2026,month:10,day:index == 2 ? 6:4),time:ClockTime(hour:2,minute:54),
            timeZoneIdentifier:"US/Pacific",reviewReasons:[.timeZoneInferred]) }
        existing.forEach { h.context.insert($0) }
        let oldScans=["old-app","old-notes"].map { ScreenshotScan(assetIdentifier:$0,status:.completed,analysisVersion:"old-version",hasDateCandidates:true) }
        oldScans.forEach { h.context.insert($0) }
        let schedule=Schedule(sourceCandidateID:UUID(),title:"Keep registered",date:CalendarDate(year:2026,month:10,day:5),
            time:ClockTime(hour:16,minute:0),timeZoneIdentifier:"US/Pacific",sourceAssetIdentifier:"old-notes",notifyDayBefore:true,notifySameDay:true,calendarExportStatus:.succeeded)
        h.context.insert(schedule);try h.context.save()
        let ids=existing.map(\.id)
        let originalTitles=Dictionary(uniqueKeysWithValues:existing.map {($0.id,$0.title)})
        let scan=try XCTUnwrap(h.queue.claimNext(owner:h.owner))
        _=try h.service.completeAnalysis(scan,owner:h.owner,drafts:[draft(key:"new",title:"New",evidence:"2026-10-07 New")],
            fragments:["Original Screenshot","Add to Calendar after registration","Notify one day before","Notify on the day"].map {
                RecognizedTextFragment(text:$0,boundingBox:CGRect(x:0.1,y:0.4,width:0.8,height:0.1),confidence:0.99)
            },settings:h.settings,analysisVersion:"unchanged")
        let stored=try h.context.fetch(FetchDescriptor<ScheduleCandidate>())
        XCTAssertEqual(Set(stored.map(\.id)),Set(ids))
        XCTAssertEqual(stored.filter {$0.reviewStatus == .pending}.count,3)
        XCTAssertEqual(Set(stored.map(\.sourceAssetIdentifier)).count,2)
        for c in stored {
            XCTAssertEqual(c.title,originalTitles[c.id])
            XCTAssertEqual(c.timeZoneIdentifier,"US/Pacific");XCTAssertEqual(c.evidenceText,"old evidence")
            XCTAssertEqual(c.reviewReasons,[.timeZoneInferred]);XCTAssertNil(c.registeredScheduleID)
        }
        XCTAssertTrue(oldScans.allSatisfy {$0.status == .completed && $0.analysisVersion == "old-version"})
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Schedule>()),1)
        XCTAssertEqual(schedule.title,"Keep registered");XCTAssertEqual(schedule.timeZoneIdentifier,"US/Pacific")
        XCTAssertTrue(schedule.notifyDayBefore && schedule.notifySameDay);XCTAssertEqual(schedule.calendarExportStatus,.succeeded)
    }

    private enum TestError: Error, Equatable {
        case insertionFailed
    }

    func testSuccessfulEmptyResultCompletesWithoutCandidates() throws {
        let harness = try makeHarness(assetIdentifiers: ["empty"])
        let claimed = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))

        let ids = try harness.service.completeAnalysis(
            claimed,
            owner: harness.owner,
            drafts: [],
            settings: harness.settings,
            analysisVersion: "parser-v1"
        )

        XCTAssertEqual(ids, [])
        XCTAssertEqual(claimed.status, .completed)
        XCTAssertEqual(claimed.hasDateCandidates, false)
        XCTAssertEqual(claimed.analysisVersion, "parser-v1")
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)
    }

    func testCreatesOnePhotoCandidateAndPreservesAllRecognizedOptionsAndSettings() throws {
        let harness = try makeHarness(assetIdentifiers: ["asset"])
        harness.settings.reminderDayBefore = false
        harness.settings.reminderSameDay = true
        harness.settings.defaultExportToCalendar = true
        let claimed = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        let first = draft(
            key: "first",
            title: "Team sync",
            evidence: "9/22 14:30 Team sync",
            location: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1),
            date: CalendarDate(year: 2026, month: 9, day: 22),
            time: ClockTime(hour: 14, minute: 30),
            timeZoneIdentifier: "Asia/Seoul",
            reasons: [.yearInferredFromCaptureDate, .ambiguousRange]
        )
        let drafts = [
            first,
            first,
            draft(key: "second", title: "Dinner", evidence: "9/22 Dinner"),
            draft(key: "third", title: "Flight", evidence: "9/23 Flight"),
        ]

        let ids = try harness.service.completeAnalysis(
            claimed,
            owner: harness.owner,
            drafts: drafts,
            settings: harness.settings,
            analysisVersion: "parser-v1"
        )

        let candidates = try fetchCandidates(harness.context)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(Set(ids), Set(candidates.map(\.id)))
        XCTAssertEqual(candidates.count, 1)
        let storedFirst = try XCTUnwrap(candidates.first { $0.sourceCandidateKey == "first" })
        XCTAssertEqual(storedFirst.sourceAssetIdentifier, "asset")
        XCTAssertEqual(storedFirst.evidenceText, first.evidenceText)
        XCTAssertEqual(storedFirst.evidenceLocation, first.evidenceLocation)
        XCTAssertEqual(storedFirst.title, first.titleSuggestion)
        XCTAssertEqual(storedFirst.date, first.date)
        XCTAssertEqual(storedFirst.time, first.time)
        XCTAssertEqual(storedFirst.timeZoneIdentifier, first.timeZoneIdentifier)
        XCTAssertEqual(storedFirst.reviewReasons, [.yearInferredFromCaptureDate, .ambiguousRange, .ambiguousDate])
        XCTAssertEqual(storedFirst.recognizedDateOptions.count, 3)
        XCTAssertEqual(storedFirst.recognizedDateOptions[0].date, first.date)
        XCTAssertEqual(storedFirst.recognizedDateOptions[0].time, first.time)
        XCTAssertEqual(storedFirst.recognizedDateOptions[0].reviewReasons, [.yearInferredFromCaptureDate, .ambiguousRange])
        XCTAssertEqual(storedFirst.dateEntries.count, 1)
        XCTAssertFalse(storedFirst.notifyDayBefore)
        XCTAssertTrue(storedFirst.notifySameDay)
        XCTAssertTrue(storedFirst.calendarExportRequested)
        XCTAssertEqual(storedFirst.reviewStatus, .pending)
        XCTAssertEqual(claimed.status, .completed)
        XCTAssertEqual(claimed.hasDateCandidates, true)
    }

    func testRepeatedDeliveryKeepsExistingCandidateAndReturnsItsID() throws {
        let harness = try makeHarness(assetIdentifiers: ["asset"])
        let claimed = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        let originalIDs = try harness.service.completeAnalysis(
            claimed,
            owner: harness.owner,
            drafts: [draft(key: "stable", title: "Original", evidence: "9/22 Original")],
            settings: harness.settings,
            analysisVersion: "parser-v1"
        )
        claimed.status = .analyzing
        try harness.context.save()

        let repeatedIDs = try harness.service.completeAnalysis(
            claimed,
            owner: harness.owner,
            drafts: [draft(key: "stable", title: "Changed suggestion", evidence: "9/22 Original")],
            settings: harness.settings,
            analysisVersion: "parser-v1"
        )

        let candidates = try fetchCandidates(harness.context)
        XCTAssertEqual(repeatedIDs, originalIDs)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].title, "Original")
    }

    func testSameDateWithDifferentEvidenceAndSameEventFromDifferentAssetsArePreserved() throws {
        let harness = try makeHarness(assetIdentifiers: ["asset-a", "asset-b"])
        let date = CalendarDate(year: 2026, month: 9, day: 22)
        let firstScan = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        try harness.service.completeAnalysis(
            firstScan,
            owner: harness.owner,
            drafts: [
                draft(key: "row-a", title: "Event A", evidence: "Row A", date: date),
                draft(key: "row-b", title: "Event B", evidence: "Row B", date: date),
            ],
            settings: harness.settings,
            analysisVersion: nil
        )
        let secondScan = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        try harness.service.completeAnalysis(
            secondScan,
            owner: harness.owner,
            drafts: [draft(key: "row-a", title: "Event A", evidence: "Row A", date: date)],
            settings: harness.settings,
            analysisVersion: nil
        )

        let candidates = try fetchCandidates(harness.context)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first { $0.sourceAssetIdentifier == firstScan.assetIdentifier }?.recognizedDateOptions.count, 2)
        XCTAssertEqual(Set(candidates.map(\.sourceAssetIdentifier)), Set(["asset-a", "asset-b"]))
    }

    func testSettingsAreCopiedAtCreationAndDoNotChangeExistingCandidates() throws {
        let harness = try makeHarness(assetIdentifiers: ["asset-a", "asset-b"])
        harness.settings.reminderDayBefore = true
        harness.settings.reminderSameDay = false
        harness.settings.defaultExportToCalendar = false
        let firstScan = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        try harness.service.completeAnalysis(
            firstScan,
            owner: harness.owner,
            drafts: [draft(key: "first", title: "First", evidence: "First")],
            settings: harness.settings,
            analysisVersion: nil
        )

        harness.settings.reminderDayBefore = false
        harness.settings.reminderSameDay = true
        harness.settings.defaultExportToCalendar = true
        let secondScan = try XCTUnwrap(harness.queue.claimNext(owner: harness.owner))
        try harness.service.completeAnalysis(
            secondScan,
            owner: harness.owner,
            drafts: [draft(key: "second", title: "Second", evidence: "Second")],
            settings: harness.settings,
            analysisVersion: nil
        )

        let candidates = try fetchCandidates(harness.context)
        let first = try XCTUnwrap(candidates.first { $0.title == "First" })
        let second = try XCTUnwrap(candidates.first { $0.title == "Second" })
        XCTAssertTrue(first.notifyDayBefore)
        XCTAssertFalse(first.notifySameDay)
        XCTAssertFalse(first.calendarExportRequested)
        XCTAssertFalse(second.notifyDayBefore)
        XCTAssertTrue(second.notifySameDay)
        XCTAssertTrue(second.calendarExportRequested)
    }

    func testInsertionFailureRollsBackCandidatesAndCompletionThenRetrySucceeds() throws {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized([asset("asset")]))
        let owner = try queue.beginExecution()
        let claimed = try XCTUnwrap(queue.claimNext(owner: owner))
        let settings = try makeSettings()
        let failingService = CandidateCreationService(context: context, scanQueue: queue) { _, index in
            if index == 0 { throw TestError.insertionFailed }
        }
        let drafts = [
            draft(key: "undated", title: "Chat", evidence: "14:00", date: nil),
            draft(key: "first", title: "First", evidence: "First"),
            draft(key: "second", title: "Second", evidence: "Second"),
        ]

        XCTAssertThrowsError(
            try failingService.completeAnalysis(
                claimed,
                owner: owner,
                drafts: drafts,
                settings: settings,
                analysisVersion: "parser-v1"
            )
        ) {
            XCTAssertEqual($0 as? TestError, .insertionFailed)
        }
        XCTAssertEqual(failingService.lastExclusions, CandidateExclusionCounts())
        XCTAssertEqual(claimed.status, .analyzing)
        XCTAssertNil(claimed.analyzedAt)
        XCTAssertNil(claimed.hasDateCandidates)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 0)

        let ids = try CandidateCreationService(context: context, scanQueue: queue).completeAnalysis(
            claimed,
            owner: owner,
            drafts: drafts,
            settings: settings,
            analysisVersion: "parser-v1"
        )
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(claimed.status, .completed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleCandidate>()), 1)
    }

    func testRejectsUndatedAndInvalidDraftsButCompletesScanNormally() throws {
        let h = try makeHarness(assetIdentifiers: ["ordinary-screen"])
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let ids = try h.service.completeAnalysis(
            scan, owner: h.owner,
            drafts: [
                draft(key: "clock", title: "Chat", evidence: "Chat 14:00", date: nil,
                      time: ClockTime(hour: 14, minute: 0), reasons: [.missingDate]),
                draft(key: "invalid", title: "Invalid", evidence: "2026-02-30",
                      date: CalendarDate(year: 2026, month: 2, day: 30)),
            ], settings: h.settings, analysisVersion: "task29"
        )
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(h.service.lastExclusions.undatedDraftCount, 2)
        XCTAssertEqual(try fetchCandidates(h.context).count, 0)
        XCTAssertEqual(scan.status, .completed)
        XCTAssertEqual(scan.hasDateCandidates, false)
        XCTAssertNil(scan.failureCode)
        try h.queue.endExecution(owner: h.owner)
        try h.queue.prepare(for: .authorized([asset("ordinary-screen")]))
        let nextOwner = try h.queue.beginExecution()
        XCTAssertNil(try h.queue.claimNext(owner: nextOwner))
    }

    func testCroppedAppOptionsCannotCombineDifferentEventsIntoRegisteredMatch() throws {
        let h = try makeHarness(assetIdentifiers: ["external"])
        h.context.insert(Schedule(sourceCandidateID: UUID(), title: "Meeting",
                                  date: CalendarDate(year: 2026, month: 10, day: 3),
                                  time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul",
                                  sourceAssetIdentifier: "old"))
        try h.context.save()
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let ids = try h.service.completeAnalysis(
            scan, owner: h.owner,
            drafts: [
                draft(key: "meeting", title: "Meeting", evidence: "Meeting 2026-10-04 15:00",
                      date: CalendarDate(year: 2026, month: 10, day: 4),
                      time: ClockTime(hour: 15, minute: 0), timeZoneIdentifier: "Asia/Seoul"),
                draft(key: "workshop", title: "Workshop", evidence: "Workshop 2026-10-03 14:00",
                      date: CalendarDate(year: 2026, month: 10, day: 3),
                      time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul"),
            ], fragments: croppedOptionFragments(), settings: h.settings, analysisVersion: "task29"
        )
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(h.service.lastExclusions.appScreenImageCount, 0)
    }

    func testCroppedAppOptionsPreserveTimedEventWhenRegisteredEventIsAllDay() throws {
        let h = try makeHarness(assetIdentifiers: ["external"])
        h.context.insert(Schedule(sourceCandidateID: UUID(), title: "Meeting",
                                  date: CalendarDate(year: 2026, month: 10, day: 3), sourceAssetIdentifier: "old"))
        try h.context.save()
        let scan = try XCTUnwrap(h.queue.claimNext(owner: h.owner))
        let ids = try h.service.completeAnalysis(
            scan, owner: h.owner,
            drafts: [draft(key: "timed", title: "Meeting", evidence: "Meeting 2026-10-03 14:00",
                           date: CalendarDate(year: 2026, month: 10, day: 3),
                           time: ClockTime(hour: 14, minute: 0), timeZoneIdentifier: "Asia/Seoul")],
            fragments: croppedOptionFragments(), settings: h.settings, analysisVersion: "task29"
        )
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(h.service.lastExclusions.appScreenImageCount, 0)
    }

    private func croppedOptionFragments() -> [RecognizedTextFragment] {
        ["Calendar copy", "One day before", "On the day"].map {
            RecognizedTextFragment(text: $0, boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1), confidence: 0.99)
        }
    }

    private func makeHarness(assetIdentifiers: [String]) throws -> Harness {
        let context = try makeContext()
        let queue = ScanQueue(context: context)
        try queue.prepare(for: .authorized(assetIdentifiers.map(asset)))
        let owner = try queue.beginExecution()
        return Harness(
            context: context,
            queue: queue,
            owner: owner,
            service: CandidateCreationService(context: context, scanQueue: queue),
            settings: try makeSettings()
        )
    }

    private func makeContext() throws -> ModelContext {
        let context = ModelContext(try SnapScheduleModelContainer.makeInMemory())
        context.autosaveEnabled = false
        return context
    }

    private func makeSettings() throws -> AppSettings {
        let suiteName = "CandidateCreationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AppSettings(userDefaults: defaults)
    }

    private func fetchCandidates(_ context: ModelContext) throws -> [ScheduleCandidate] {
        try context.fetch(FetchDescriptor<ScheduleCandidate>())
            .sorted { $0.sourceCandidateKey < $1.sourceCandidateKey }
    }

    private func asset(_ identifier: String) -> ScreenshotAssetMetadata {
        ScreenshotAssetMetadata(
            assetIdentifier: identifier,
            creationDate: nil,
            pixelWidth: 100,
            pixelHeight: 200
        )
    }

    private func draft(
        key: String,
        title: String,
        evidence: String,
        location: NormalizedRect = NormalizedRect(x: 0, y: 0, width: 1, height: 0.1),
        date: CalendarDate? = CalendarDate(year: 2026, month: 9, day: 22),
        time: ClockTime? = nil,
        timeZoneIdentifier: String? = nil,
        reasons: [DateTimeReviewReason] = [],
        rangeRole: DateTimeRangeRole = .standalone
    ) -> DateTimeCandidateDraft {
        DateTimeCandidateDraft(
            titleSuggestion: title,
            date: date,
            time: time,
            timeZoneIdentifier: timeZoneIdentifier,
            evidenceText: evidence,
            evidenceLocation: location,
            reviewReasons: reasons,
            rangeRole: rangeRole,
            sourceKeyMaterial: key
        )
    }

    private struct Harness {
        let context: ModelContext
        let queue: ScanQueue
        let owner: UUID
        let service: CandidateCreationService
        let settings: AppSettings
    }
}
