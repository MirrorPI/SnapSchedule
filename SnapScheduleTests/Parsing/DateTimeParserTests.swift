import CoreGraphics
import Foundation
import XCTest
@testable import SnapSchedule

final class DateTimeParserTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    func testDeadlineBeforeOrdinalSurvivesContestWordsAndDistinctNamedContestsNeverMerge() {
        for text in ["Submission due the 8th for Photo Contest", "Deadline: the 8th for the competition", "Deadline is the 8th for the film festival"] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)], captureDate: nil,
                analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertEqual(drafts.compactMap(\.date), [CalendarDate(year: 2026, month: 10, day: 8)], text)
        }
        let fragments = [fragment("Nature Photo Contest", y: 0.9), fragment("2026-09-01 ~ 2026-10-18", y: 0.7),
                         fragment("Urban Nature Photo Contest", y: 0.5), fragment("2026-09-23 ~ 2026-10-18", y: 0.3)]
        let drafts = DateTimeParser().parse(fragments: fragments, captureDate: nil,
            analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
        XCTAssertEqual(drafts.count, 4, "Additional words identify a different contest, even with the same closing date")
    }

    func testContestSubmissionPeriodProducesOnlyItsDeadlineWithItsTitleInThreeLanguages() {
        let cases = [
            ("7th Da-Ho Award Asian International Short Film Competition(단편영화 공모전)", "2026-08-01 ~ 2027-01-15 D-100", CalendarDate(year: 2027, month: 1, day: 15)),
            ("LG 대국민 미소 사진 공모전 - 스마일 모먼트", "2026.09.23 - 10.18", CalendarDate(year: 2026, month: 10, day: 18)),
            ("第7回 写真コンテスト", "2026.09.23 ～ 10.18", CalendarDate(year: 2026, month: 10, day: 18)),
        ]
        for (title, period, deadline) in cases {
            let genericTitle = title.contains("Da-Ho") ? "단편영화 공모전" : title.contains("LG") ? "대국민 미소 사진 공모전" : "写真コンテスト"
            let drafts = DateTimeParser().parse(fragments: [fragment(title, y: 0.8), fragment(genericTitle, y: 0.6),
                fragment("WEVITY 공모전 대외활동", y: 0.95), fragment(period, y: 0.4)],
                captureDate: makeDate(2026, 10, 7), analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertEqual(drafts.count, 1, title)
            XCTAssertEqual(drafts.first?.date, deadline, title)
            XCTAssertEqual(drafts.first?.titleSuggestion, String(title.prefix(60)), title)
            XCTAssertNil(drafts.first?.time, title)
            XCTAssertTrue(drafts.first?.evidenceText.contains(period) == true)
            XCTAssertTrue(drafts.first?.evidenceText.contains(title) == true)
        }
    }

    func testRepeatedPosterAndSubmissionTableKeepOneDeadlineWithoutChangingEndSourceKey() throws {
        let title = "7th Da-Ho Award Short Film Competition"
        let dateRow = fragment("접수기간 2026-08-01 ~ 2027-01-15 D-100", y: 0.2)
        let fragments = [fragment(title, y: 0.8), fragment("2026.8.15 ~ 2027.1.15", y: 0.6), dateRow]
        let parser = DateTimeParser()
        let onlyRow = parser.parse(fragments: fragments.enumerated().map { index, f in
            RecognizedTextFragment(text: f.text, boundingBox: f.boundingBox, confidence: index == 0 ? 0.49 : f.confidence)
        }, captureDate: nil, analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
        let expectedKey = try XCTUnwrap(onlyRow.first { $0.rangeRole == .end && $0.evidenceText.contains("접수기간") }).sourceKeyMaterial
        let drafts = parser.parse(fragments: fragments, captureDate: nil, analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2027, month: 1, day: 15))
        XCTAssertEqual(drafts.first?.titleSuggestion, title)
        XCTAssertEqual(drafts.first?.sourceKeyMaterial, expectedKey)
        XCTAssertTrue(drafts.first?.evidenceText.contains(dateRow.text) == true)
    }

    func testContestDeadlineDoesNotCollapseUncertainRangesOrIndependentEvents() {
        let title = fragment("Photo contest", y: 0.8)
        for fragments in [
            [title, fragment("2026-09-23 ~ 2026-10-18", y: 0.5), fragment("2026-11-01 ~ 2026-11-30", y: 0.2)],
            [title, fragment("Film competition", y: 0.7), fragment("2026-09-23 ~ 2026-10-18", y: 0.5)],
            [RecognizedTextFragment(text: title.text, boundingBox: title.boundingBox, confidence: 0.49), fragment("2026-09-23 ~ 2026-10-18", y: 0.5)],
            [title, fragment("2026-10-18 ~ 2026-09-23", y: 0.5)],
            [fragment("Travel booking", y: 0.8), fragment("2026-09-23 ~ 2026-10-18", y: 0.5)],
            [title, fragment("Workshop 2026-09-23 ~ 2026-10-18", y: 0.5)],
        ] {
            let drafts = DateTimeParser().parse(fragments: fragments, captureDate: nil,
                analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertGreaterThanOrEqual(drafts.filter { $0.date != nil }.count, 2, fragments.map(\.text).joined(separator: " | "))
        }
        let fragments = [title, fragment("2026-09-23 ~ 2026-10-18", y: 0.5), fragment("Award ceremony 2026-12-01", y: 0.2)]
        let drafts = DateTimeParser().parse(fragments: fragments, captureDate: nil,
            analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
        XCTAssertTrue(drafts.contains { $0.date == CalendarDate(year: 2026, month: 12, day: 1) && $0.titleSuggestion == "Award ceremony" })
    }

    func testEventEditionOrdinalsDoNotBecomeNearestDayDates() {
        for text in [
            "7th Da-Ho Award Asian International Short Film Competition(단편영화 공모전)",
            "The 21st International Film Festival",
            "Join the 3rd Annual Design Competition",
            "7th Photography Contest",
            "10th International Conference",
        ] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)], captureDate: nil,
                analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty, text)
        }
        for text in ["Submit to the competition by the 8th", "On the 8th attend the conference",
                     "Award application deadline 8th", "8th submission deadline"] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)], captureDate: nil,
                analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertEqual(drafts.compactMap(\.date), [CalendarDate(year: 2026, month: 10, day: 8)], text)
        }
        let dated = "7th Da-Ho Award Short Film Competition 2026-08-01 ~ 2027-01-15"
        let drafts = DateTimeParser().parse(fragments: [fragment(dated, y: 0.6)], captureDate: nil,
            analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
        XCTAssertEqual(drafts.compactMap(\.date), [CalendarDate(year: 2026, month: 8, day: 1),
                                               CalendarDate(year: 2027, month: 1, day: 15)])
    }

    func testTaskWordsAndReportNumbersDoNotBecomeMonthOrYearQualifiers() {
        for text in ["You may submit by Wednesday", "Review the grammar report by Wednesday", "Submit report #1234 by Wednesday",
                     "You may submit the report Wednesday", "By Wednesday you may draft the report"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertEqual(drafts.compactMap(\.date),[CalendarDate(year:2026,month:10,day:7)],text)
        }
    }

    func testQualifiedTaskClausesPreserveModifiersBeforeOrAfterTheTask() {
        for text in ["Next week, submit on Wednesday", "Next month, submit on the 8th", "다음 주, 수요일 보고서 제출", "来週, 水曜日に報告書を提出",
                     "Wednesday meeting next week", "Next week's Wednesday meeting", "수요일 회의 다음 주", "水曜日の会議は来週", "8일 보고서 제출 다음 달"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty,text)
        }
    }

    func testDateMarkersAndJoinedExistingDeadlineAreNotOrdinalCounters() {
        for text in ["On the 8th draft the report", "by the 8th draft the report", "8日 draft the report", "8일까지보고서 제출"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertEqual(drafts.compactMap(\.date),[CalendarDate(year:2026,month:10,day:8)],text)
            XCTAssertTrue(drafts.allSatisfy {$0.time == nil})
        }
    }

    func testOrdinalDraftAndJapaneseDayCountersAreNotDates() {
        for text in ["Submit the 1st draft Wednesday", "Submit the 3rd quarter report on Wednesday"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertEqual(drafts.compactMap(\.date),[CalendarDate(year:2026,month:10,day:7)],text)
        }
        for text in ["研修1日目の資料提出", "8th place prize", "the 2nd edition report"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty,text)
        }
    }

    func testPlainDayParticlesAndWeekdayAnnotationsProduceOneReviewedDay() {
        for text in ["8일에 보고서 제출", "8일(목요일) 보고서 제출", "Submit on the 8th (Thursday)", "8日（木曜日）に報告書を提出"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,9),timeZone:seoul)
            XCTAssertEqual(drafts.compactMap(\.date),[CalendarDate(year:2026,month:11,day:8)],text)
            XCTAssertTrue(drafts.allSatisfy {$0.reviewReasons.contains(.relativeDateBasedOnAnalysisDate)})
            XCTAssertTrue(drafts.allSatisfy {$0.time == nil})
        }
    }

    func testPlainDatesKeepCommaAndAbbreviatedMonthQualifiersOutOfNearestFallback() {
        for text in ["Submit Wednesday, next week", "Submit by Wednesday, next week", "Submit on the 8th, next month",
                     "보고서 제출 수요일, 다음 주", "報告書提出 水曜日, 来週", "水曜日、来週に報告書提出",
                     "翌週の水曜日に提出", "Submit Wed, Nov 18", "Submit Wed Nov 18", "Submit Nov 18 Wed", "on Nov 8th submit",
                     "다음 달 수요일 보고서 제출", "수요일 다음 달 제출", "submit Wednesday next month", "next month on Wednesday submit", "来月の水曜日に提出",
                     "2027년 수요일 제출", "2027年の水曜日に提出", "on the 8th in 2027 submit", "8일(2027년) 제출", "8日（2027年）提出",
                     "11월 수요일 제출", "11月の水曜日に提出", "Submit Wednesday in November",
                     "내년 수요일 제출", "내년 8일 제출", "submit Wednesday next year", "next year on the 8th submit", "来年の水曜日に提出", "8日（来年）提出"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty,text)
        }
    }

    func testPlainWeekdaysUseTodayOrNextOccurrenceInAllLanguages() throws {
        let weekdays = [
            ["월요일", "Monday", "月曜日"], ["화요일", "Tuesday", "火曜日"],
            ["수요일", "Wednesday", "水曜日"], ["목요일", "Thursday", "木曜日"],
            ["금요일", "Friday", "金曜日"], ["토요일", "Saturday", "土曜日"],
            ["일요일", "Sunday", "日曜日"]
        ]
        for (weekday, names) in weekdays.enumerated() {
            let texts = ["\(names[0]) 보고서 제출", "Submit the report \(names[1])", "\(names[2])に報告書を提出"]
            for text in texts {
                for today in [7, 8] {
                    let offset = (weekday - (today == 7 ? 2 : 3) + 7) % 7
                    let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                        captureDate: makeDate(2026, 9, 1), analysisDate: makeDate(2026, 10, today), timeZone: seoul)
                    XCTAssertEqual(drafts.count, 1, text)
                    let draft = try XCTUnwrap(drafts.first)
                    XCTAssertEqual(draft.date, CalendarDate(year: 2026, month: 10, day: today + offset), text)
                    XCTAssertNil(draft.time); XCTAssertNil(draft.timeZoneIdentifier)
                    XCTAssertEqual(draft.reviewReasons, [.relativeDate, .relativeDateBasedOnAnalysisDate], text)
                    XCTAssertEqual(draft.evidenceText, text)
                    XCTAssertFalse(draft.titleSuggestion.isEmpty)
                }
            }
        }
    }

    func testPlainDaysUseNearestValidMonthIncludingTodayYearEndAndLeapYears() throws {
        for (year, month, today, day, wantYear, wantMonth) in [
            (2026,10,7,8,2026,10), (2026,10,8,8,2026,10), (2026,10,9,8,2026,11),
            (2026,12,31,8,2027,1), (2026,2,1,31,2026,3), (2027,2,28,29,2027,3),
            (2028,2,28,29,2028,2), (2028,2,29,29,2028,2), (2028,3,30,29,2028,4),
            (2026,4,30,31,2026,5), (2026,12,31,31,2026,12)
        ] {
            let ordinal = day == 31 ? "31st" : "\(day)th"
            for text in ["\(day)일 보고서 제출", "Submit the report on the \(ordinal)", "\(day)日に報告書を提出"] {
                let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                    captureDate: makeDate(2025, 1, 1), analysisDate: makeDate(year, month, today), timeZone: seoul)
                XCTAssertEqual(drafts.count, 1, text)
                let draft = try XCTUnwrap(drafts.first)
                XCTAssertEqual(draft.date, CalendarDate(year: wantYear, month: wantMonth, day: day), text)
                XCTAssertNil(draft.time); XCTAssertNil(draft.timeZoneIdentifier)
                XCTAssertEqual(draft.reviewReasons, [.relativeDate, .relativeDateBasedOnAnalysisDate])
            }
        }
    }

    func testPlainDateInferenceUsesSuppliedDeviceZoneWithoutChangingIt() throws {
        // One instant is Wednesday October 7 in Seoul and Tuesday October 6 in Pacific.
        let instant = makeDate(2026, 10, 7)
        let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (zone, expectedDay) in [(seoul, 7), (pacific, 6)] {
            for text in ["화요일 보고서 제출", "Submit the report Tuesday", "火曜日に報告書を提出"] {
                let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                    captureDate: nil, analysisDate: instant, timeZone: zone)
                XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2026, month: 10, day: expectedDay == 7 ? 13 : 6), text)
            }
        }
        for text in ["8일 보고서 제출 16:00", "Submit the report on the 8th at 16:00", "8日に報告書を提出 16:00"] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                captureDate: nil, analysisDate: instant, timeZone: pacific)
            XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2026, month: 10, day: 8))
            XCTAssertEqual(drafts.first?.time, ClockTime(hour: 16, minute: 0))
            XCTAssertEqual(drafts.first?.timeZoneIdentifier, pacific.identifier)
        }
    }

    func testPlainDatesRejectCalendarHeadingsNumbersDurationsAndQualifiers() {
        let texts = [
            "월요일 화요일 수요일 목요일 금요일 토요일 일요일", "Mon Tue Wed Thu Fri Sat Sun", "月曜日 火曜日 水曜日 木曜日 金曜日 土曜日 日曜日",
            "October 2026 Mon Tue Wed Thu Fri Sat Sun", "10월 월요일 화요일 수요일 목요일 금요일 토요일 일요일", "10月 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日 日曜日",
            "수요일", "Wednesday", "水曜日", "보고서 제출 8", "Submit report 8", "報告書 8", "123",
            "8일 동안 작업", "8일간 작업", "8일 후 제출", "8日前に提出", "8日間の作業", "8日後に提出", "work for 8 days",
            "32일 제출", "0일 제출", "132일 제출", "32日に提出", "on the 32nd submit",
            "다음 주 수요일 보고서 제출", "지난 주 수요일 제출", "수요일 다음 주 제출", "next Wednesday submit", "submit Wednesday next week", "last Wednesday submit", "submit this Wednesday", "来週の水曜日に提出", "水曜日（来週）提出",
            "다음 달 8일 제출", "이번 달 8일 제출", "지난 달 8일 제출", "8일 다음 달 제출", "来月の8日に提出", "8日（来月）提出", "submit on the 8th of next month", "next month on the 8th submit", "on November 8th submit", "on the 8th of November submit",
            "2027년 2월 29일 제출", "2027年2月29日に提出", "2026-02-30 (Wednesday) submit"
        ]
        for text in texts {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                captureDate: nil, analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty, "Must not use nearest date: \(text)")
        }
    }

    func testPlainWeekdayAnnotationsPreserveExplicitDatesAndNamedMonthGuards() {
        for text in ["2026-11-18（수요일） 보고서 제출", "2026年11月18日（水曜日）報告書提出",
                     "Submit Wednesday, 2026-11-18", "Submit 2026-11-18 (Wednesday)", "Submit 11/18 Wednesday"] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                captureDate: nil, analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertEqual(drafts.compactMap(\.date), [CalendarDate(year: 2026, month: 11, day: 18)], text)
        }
        for text in ["Submit Wednesday, November 18", "Submit Wednesday November 18", "Submit November 18 Wednesday"] {
            let drafts = DateTimeParser().parse(fragments: [fragment(text, y: 0.6)],
                captureDate: nil, analysisDate: makeDate(2026, 10, 7), timeZone: seoul)
            XCTAssertTrue(drafts.compactMap(\.date).isEmpty, text)
        }
    }

    func testNearbyDeadlineRowsDoNotBecomeEachOthersTitleOrEvidence() {
        for texts in [["by the 8th","by the 9th"],["by Wednesday","by Thursday"]] {
            let drafts=DateTimeParser().parse(fragments:[fragment(texts[0],y:0.6,height:0.03),fragment(texts[1],y:0.56,height:0.03)],
                captureDate:nil,analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertEqual(drafts.count,2)
            XCTAssertEqual(drafts.map(\.evidenceText),texts)
            XCTAssertTrue(drafts.allSatisfy {$0.reviewReasons.contains(.missingTitle)})
        }
        let titled=DateTimeParser().parse(fragments:[fragment("Shared report",x:0.11,y:0.68,height:0.08),
            fragment("by the 8th",x:0.1,y:0.635,height:0.02),fragment("by the 9th",x:0.125,y:0.58,height:0.02)],
            captureDate:nil,analysisDate:makeDate(2026,10,7),timeZone:seoul)
        XCTAssertEqual(titled.count,2)
        XCTAssertEqual(titled.first?.titleSuggestion,"Shared report")
        XCTAssertTrue(titled.last?.reviewReasons.contains(.missingTitle) == true)
    }

    func testWeekdayWithNamedMonthDateDoesNotUseBareWeekdayFallback() {
        for text in ["send by Wednesday, November 18", "send by Wednesday November 18", "send by Wednesday, 2026-11-18"] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul)
            XCTAssertFalse(drafts.contains {$0.date == CalendarDate(year:2026,month:10,day:7)},text)
            if text.contains("2026") { XCTAssertEqual(drafts.compactMap(\.date),[CalendarDate(year:2026,month:11,day:18)]) }
        }
    }

    func testBareDeadlinesDoNotOverrideInvalidExplicitDatesOrQualifiedMonthsAndWeeks() {
        let texts = [
            "2026년 2월 30일까지 제출", "2026年2月 30日までに提出",
            "2027년 2월 29일까지 제출", "2027年2月29日までに提出",
            "다음 달 8일까지 제출", "이번 달 8일까지 제출", "지난달 8일까지 제출",
            "by the 8th of next month submit", "by the 8th next month submit", "by the 8th of this month submit",
            "来月の8日までに提出", "今月8日までに提出", "先月の8日までに提出",
            "send the report by Wednesday next week", "by Wednesday of next week submit", "by Wednesday last week submit"
        ]
        for text in texts {
            let dates = DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2028,10,7),timeZone:seoul).compactMap(\.date)
            XCTAssertTrue(dates.isEmpty,text)
        }
    }

    func testExplicitDateWeekdayDeadlineAnnotationsDoNotCreateAnotherDate() {
        for text in ["2026-11-18（수요일까지） 제출", "2026年11月18日（水曜日まで）提出",
                     "2026-11-18 (by Wednesday) submit", "2026-11-18 [until Wednesday] submit"] {
            let dates = DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,
                analysisDate:makeDate(2026,10,7),timeZone:seoul).compactMap(\.date)
            XCTAssertEqual(dates,[CalendarDate(year:2026,month:11,day:18)],text)
        }
    }

    func testAdjacentJapaneseExplicitDatesKeepSeparateEvidenceAndNoBorrowedTitle() {
        let drafts = DateTimeParser().parse(fragments:[fragment("2026年10月8日",y:0.6),fragment("2026年10月9日",y:0.56)],
            captureDate:nil,analysisDate:makeDate(2026,10,7),timeZone:seoul)
        XCTAssertEqual(drafts.count,2)
        for draft in drafts {
            XCTAssertTrue(draft.reviewReasons.contains(.missingTitle))
            XCTAssertFalse(draft.evidenceText.contains("\n"))
        }
    }

    func testBareWeekdayDeadlinesUseNearestAnalysisDateInThreeLanguages() throws {
        for text in ["수요일까지 보고서를 보내주세요", "Please send the report by Wednesday", "水曜日までに報告書を送ってください"] {
            for (today,expected) in [(7,7),(8,14)] {
                let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:makeDate(2026,9,30),analysisDate:makeDate(2026,10,today),timeZone:seoul)
                XCTAssertEqual(drafts.count,1,text)
                let d=try XCTUnwrap(drafts.first)
                XCTAssertEqual(d.date,CalendarDate(year:2026,month:10,day:expected),text)
                XCTAssertNil(d.time,text)
                XCTAssertTrue(d.reviewReasons.contains(.relativeDateBasedOnAnalysisDate),text)
                XCTAssertEqual(d.evidenceText,text)
            }
        }
    }

    func testDayOnlyDeadlinesRollToNearestValidDateInThreeLanguages() throws {
        for text in ["8일까지 보고서를 보내주세요", "Please send the report by the 8th", "8日までに報告書を送ってください"] {
            for (year,month,day,wantYear,wantMonth,wantDay) in [(2026,10,7,2026,10,8),(2026,10,8,2026,10,8),(2026,10,9,2026,11,8),(2026,12,31,2027,1,8)] {
                let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:makeDate(2026,9,1),analysisDate:makeDate(year,month,day),timeZone:seoul)
                XCTAssertEqual(drafts.count,1,text)
                let d=try XCTUnwrap(drafts.first)
                XCTAssertEqual(d.date,CalendarDate(year:wantYear,month:wantMonth,day:wantDay),text)
                XCTAssertTrue(d.reviewReasons.contains(.relativeDateBasedOnAnalysisDate))
                XCTAssertNil(d.time)
            }
        }
        for (text,year,month,day,wantMonth,wantDay) in [("31일까지 제출",2026,2,1,3,31),("by the 29th submit",2027,2,28,3,29),("29日までに提出",2028,2,28,2,29)] {
            let drafts=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,analysisDate:makeDate(year,month,day),timeZone:seoul)
            XCTAssertEqual(drafts.first?.date,CalendarDate(year:year,month:wantMonth,day:wantDay),text)
        }
    }

    func testDeadlineInferencePreservesExplicitDatesAndRejectsDurationsAndInvalidDays() {
        for text in ["8일 동안 작업", "8日間の作業", "finish within 8 days", "32일까지 제출", "0日までに提出", "by the 32nd submit", "다음 주 수요일 제출", "next Wednesday submit", "来週の水曜日までに提出"] {
            let dates=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,analysisDate:makeDate(2026,10,8),timeZone:seoul).filter {$0.date != nil}
            XCTAssertTrue(dates.isEmpty,text)
        }
        for text in ["회의 2026-10-10 수요일", "Meeting 2026-10-10 Wednesday", "会議 2026年10月10日 水曜日", "2026년 11월 8일까지 제출", "2026年11月8日までに提出"] {
            let dates=DateTimeParser().parse(fragments:[fragment(text,y:0.6)],captureDate:nil,analysisDate:makeDate(2026,10,8),timeZone:seoul).compactMap(\.date)
            let expected = text.contains("11") ? CalendarDate(year:2026,month:11,day:8):CalendarDate(year:2026,month:10,day:10)
            XCTAssertEqual(dates,[expected],text)
        }
    }

    func testNoteMetadataFilterKeepsRealDatesWhenAnyLayoutClueIsUncertain() throws {
        let texts=["2026년 10월 4일 오전 2:54","Application","2026년 10월 6일 오후 4시","장소: 테스트룸","Aa","123"]
        let boxes=[CGRect(x:0.273,y:0.874,width:0.376,height:0.017),CGRect(x:0.059,y:0.83,width:0.449,height:0.032),
                   CGRect(x:0.059,y:0.795,width:0.395,height:0.022),CGRect(x:0.059,y:0.768,width:0.215,height:0.023),
                   CGRect(x:0.05,y:0.40,width:0.10,height:0.025),CGRect(x:0.03,y:0.10,width:0.08,height:0.02)]
        let clear=zip(texts,boxes).map { RecognizedTextFragment(text:$0.0,boundingBox:$0.1,confidence:0.99) }
        func parse(_ fragments:[RecognizedTextFragment])->[DateTimeCandidateDraft] {
            DateTimeParser().parse(fragments:fragments,captureDate:makeDate(2026,10,4),analysisDate:makeDate(2026,10,7),timeZone:seoul)
        }
        let kept=parse(clear)
        XCTAssertEqual(kept.count,1);XCTAssertEqual(kept.first?.date,CalendarDate(year:2026,month:10,day:6))
        let variants: [(String,[RecognizedTextFragment])] = [
            ("same geometry flyer",Array(clear.prefix(4))),
            ("weak formatting",clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:f.boundingBox,confidence:i == 4 ? 0.49:f.confidence) }),
            ("misplaced keyboard",clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:i == 5 ? CGRect(x:0.8,y:0.6,width:0.08,height:0.02):f.boundingBox,confidence:f.confidence) }),
            ("no keyboard",Array(clear.dropLast())),
            ("no formatting",clear.enumerated().filter {$0.offset != 4}.map(\.element)),
            ("single date",[clear[0]]),
            ("no title",clear.enumerated().filter {$0.offset != 1}.map(\.element)),
            ("weak header",clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:f.boundingBox,confidence:i == 0 ? 0.49:f.confidence) }),
            ("left aligned event",clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:i == 0 ? CGRect(x:0.059,y:0.874,width:0.376,height:0.017):f.boundingBox,confidence:f.confidence) }),
            ("titled date",clear.enumerated().map { i,f in RecognizedTextFragment(text:i == 0 ? "Meeting "+f.text:f.text,boundingBox:f.boundingBox,confidence:f.confidence) }),
            ("equal title size",clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:i == 1 ? CGRect(x:0.059,y:0.83,width:0.449,height:0.017):f.boundingBox,confidence:f.confidence) })
        ]
        for (variant,fragments) in variants {
            let drafts=parse(fragments)
            XCTAssertTrue(drafts.contains {$0.date == CalendarDate(year:2026,month:10,day:4)},variant)
        }
        // Filtering metadata must not change the body's deterministic source key or evidence.
        let unfiltered=parse(clear.enumerated().map { i,f in RecognizedTextFragment(text:f.text,boundingBox:f.boundingBox,confidence:i == 0 ? 0.49:f.confidence) })
        let body=try XCTUnwrap(unfiltered.first {$0.date == CalendarDate(year:2026,month:10,day:6)})
        XCTAssertEqual(kept.first?.sourceKeyMaterial,body.sourceKeyMaterial)
        XCTAssertEqual(kept.first?.evidenceText,body.evidenceText)
    }

    func testBareWeekdayIsAReviewableDateRatherThanUndatedTime() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("금요일 상담 14:00", y: 0.6)],
            captureDate: makeDate(2026, 10, 1),
            analysisDate: makeDate(2026, 10, 1), timeZone: seoul
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2026, month: 10, day: 2))
        XCTAssertTrue(drafts.first?.reviewReasons.contains(.relativeDate) == true)
    }

    func testBareWeekdayRollsForwardWhileExplicitThisWeekKeepsItsMeaning() {
        for (expression, day) in [("금요일", 9), ("이번 주 금요일", 2)] {
            let drafts = DateTimeParser().parse(
                fragments: [fragment(expression + " 상담", y: 0.6)],
                captureDate: nil, analysisDate: makeDate(2026, 10, 3), timeZone: seoul
            )
            XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2026, month: 10, day: day))
            XCTAssertTrue(drafts.first?.reviewReasons.contains(.relativeDateBasedOnAnalysisDate) == true)
        }
    }

    func testWeekdayAnnotationDoesNotCreateAnExtraRelativeDate() {
        for expression in ["회의 2026-10-10 토요일 14:00", "회의 10/10 (토요일) 14:00", "회의 토요일 2026년 10월 10일 14:00"] {
            let drafts = DateTimeParser().parse(
                fragments: [fragment(expression, y: 0.6)],
                captureDate: makeDate(2026, 10, 1), analysisDate: makeDate(2026, 10, 1), timeZone: seoul
            )
            XCTAssertEqual(drafts.count, 1, expression)
            XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2026, month: 10, day: 10))
            XCTAssertEqual(drafts.first?.time, ClockTime(hour: 14, minute: 0))
        }
    }

    func testParsesSupportedExplicitDateAndTimeFormats() throws {
        let fragments = [
            fragment("회의 2026.09.21 23:59", y: 0.8),
            fragment("점검 2026-10-02 08:05", y: 0.7),
            fragment("예약 2026/11/03 오후 3시 7분", y: 0.6),
        ]

        let drafts = DateTimeParser().parse(
            fragments: fragments,
            captureDate: makeDate(2026, 9, 1),
            analysisDate: makeDate(2026, 9, 2),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.date), [
            CalendarDate(year: 2026, month: 9, day: 21),
            CalendarDate(year: 2026, month: 10, day: 2),
            CalendarDate(year: 2026, month: 11, day: 3),
        ])
        XCTAssertEqual(drafts.map(\.time), [
            ClockTime(hour: 23, minute: 59),
            ClockTime(hour: 8, minute: 5),
            ClockTime(hour: 15, minute: 7),
        ])
        XCTAssertEqual(drafts.map(\.titleSuggestion), ["회의", "점검", "예약"])
        XCTAssertTrue(drafts.allSatisfy { $0.reviewReasons == [.timeZoneInferred] })
    }

    func testMarksImplicitTimeZoneAndMissingTitleForReview() throws {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("회의 2026-10-03 14:00", y: 0.8),
                fragment("Call 2026-10-04 09:00 KST", y: 0.7),
                fragment("2026-10-05", y: 0.6),
            ],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts[0].reviewReasons, [.timeZoneInferred])
        XCTAssertEqual(drafts[1].reviewReasons, [])
        XCTAssertEqual(drafts[2].titleSuggestion, "일정 확인 필요")
        XCTAssertEqual(drafts[2].reviewReasons, [.missingTitle])
    }

    func testYearlessDatesUseCaptureYearWithoutRollingPastDatesForward() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("마감 1/2", y: 0.8),
                fragment("발표 9월 21일", y: 0.7),
            ],
            captureDate: makeDate(2026, 12, 31),
            analysisDate: makeDate(2027, 1, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.date), [
            CalendarDate(year: 2026, month: 1, day: 2),
            CalendarDate(year: 2026, month: 9, day: 21),
        ])
        XCTAssertTrue(drafts.allSatisfy {
            $0.reviewReasons == [.yearInferredFromCaptureDate]
        })
    }

    func testYearlessDateFallsBackToAnalysisYearAndRecordsReason() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("행사 9.21", y: 0.6)],
            captureDate: nil,
            analysisDate: makeDate(2027, 2, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2027, month: 9, day: 21))
        XCTAssertEqual(drafts.first?.reviewReasons, [.yearInferredFromAnalysisDate])
    }

    func testValidatesLeapDaysAndKeepsInvalidDateUnconfirmed() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("윤년 2028.02.29", y: 0.8),
                fragment("오류 2026.02.29", y: 0.7),
            ],
            captureDate: nil,
            analysisDate: makeDate(2026, 1, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].date, CalendarDate(year: 2028, month: 2, day: 29))
    }

    func testPreservesRangeEndpointsAndInheritsOmittedMonthOnlyInsideRange() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("행사 2026.09.14 ~ 09.21 23:59", y: 0.8),
                fragment("휴가 9월 28일~30일", y: 0.7),
            ],
            captureDate: makeDate(2026, 8, 1),
            analysisDate: makeDate(2026, 8, 2),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.rangeRole), [.start, .end, .start, .end])
        XCTAssertEqual(drafts.map(\.date), [
            CalendarDate(year: 2026, month: 9, day: 14),
            CalendarDate(year: 2026, month: 9, day: 21),
            CalendarDate(year: 2026, month: 9, day: 28),
            CalendarDate(year: 2026, month: 9, day: 30),
        ])
        XCTAssertNil(drafts[0].time)
        XCTAssertEqual(drafts[1].time, ClockTime(hour: 23, minute: 59))
        XCTAssertTrue(drafts[2...3].allSatisfy {
            $0.reviewReasons == [.yearInferredFromCaptureDate]
        })
    }

    func testResolvesRelativeDatesAndAlwaysRequiresReview() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("내일 회의", y: 0.8),
                fragment("모레 약속", y: 0.7),
                fragment("이번 주 월요일 발표", y: 0.6),
            ],
            captureDate: makeDate(2026, 12, 31),
            analysisDate: makeDate(2027, 2, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.date), [
            CalendarDate(year: 2027, month: 1, day: 1),
            CalendarDate(year: 2027, month: 1, day: 2),
            CalendarDate(year: 2026, month: 12, day: 28),
        ])
        XCTAssertTrue(drafts.allSatisfy { $0.reviewReasons == [.relativeDate] })
    }

    func testRelativeDateWithoutCaptureDateRecordsAnalysisFallback() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("내일 제출", y: 0.7)],
            captureDate: nil,
            analysisDate: makeDate(2026, 12, 31),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.first?.date, CalendarDate(year: 2027, month: 1, day: 1))
        XCTAssertEqual(
            drafts.first?.reviewReasons,
            [.relativeDate, .relativeDateBasedOnAnalysisDate]
        )
    }

    func testKeepsBodyTimeOnlyButExcludesStandaloneStatusBarTime() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("09:41", y: 0.96, height: 0.025),
                fragment("상담 14:00", y: 0.45),
            ],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 21),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertNil(drafts[0].date)
        XCTAssertEqual(drafts[0].time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(drafts[0].reviewReasons, [.missingDate, .timeZoneInferred])
        XCTAssertEqual(drafts[0].evidenceLocation, NormalizedRect(x: 0.1, y: 0.45, width: 0.8, height: 0.08))
    }

    func testDoesNotTreatPricePhoneVersionOrAmbiguousThreePartDateAsSchedule() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("가격 12,000원", y: 0.8),
                fragment("전화 010-1234-5678", y: 0.7),
                fragment("버전 v2026.09.21", y: 0.6),
                fragment("코드 03/04/05", y: 0.5),
            ],
            captureDate: makeDate(2026, 9, 21),
            analysisDate: makeDate(2026, 9, 21),
            timeZone: seoul
        )

        XCTAssertTrue(drafts.isEmpty)
    }

    func testDoesNotCombineDateAndTimeAcrossFragments() {
        let drafts = DateTimeParser().parse(
            fragments: [
                fragment("첫 문단 2026-09-21", x: 0.1, y: 0.8, width: 0.35),
                fragment("다른 문단 18:00", x: 0.6, y: 0.3, width: 0.3),
            ],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].date, CalendarDate(year: 2026, month: 9, day: 21))
        XCTAssertNil(drafts[0].time)
        XCTAssertNil(drafts[1].date)
        XCTAssertEqual(drafts[1].time, ClockTime(hour: 18, minute: 0))
    }

    func testMarksUnsupportedExplicitTimeZoneForReview() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("통화 2026-09-21 14:00 TZ: XYZ", y: 0.6)],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.first?.timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(drafts.first?.reviewReasons, [.unsupportedTimeZone])
    }

    func testAssociatesTimeZonesWithEachTimedCandidate() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment(
                "서울 2026-09-21 10:00 KST / 뉴욕 2026-09-22 10:00 TZ: XYZ",
                y: 0.6
            )],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(drafts[0].reviewReasons, [])
        XCTAssertEqual(drafts[1].timeZoneIdentifier, "Asia/Seoul")
        XCTAssertEqual(drafts[1].reviewReasons, [.unsupportedTimeZone])
    }

    func testKeepsUppercaseTitleTextInsteadOfTreatingItAsTimeZone() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("2026-09-21 14:00 TEAM", y: 0.6)],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.first?.titleSuggestion, "TEAM")
        XCTAssertEqual(drafts.first?.reviewReasons, [.timeZoneInferred])
    }

    func testDoesNotCombineUnrelatedClausesInsideOneFragment() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("14:00 접수 / 마감 2026-09-21", y: 0.6)],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 2)
        XCTAssertNil(drafts[0].date)
        XCTAssertEqual(drafts[0].time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(drafts[0].titleSuggestion, "접수")
        XCTAssertEqual(drafts[1].date, CalendarDate(year: 2026, month: 9, day: 21))
        XCTAssertNil(drafts[1].time)
        XCTAssertEqual(drafts[1].titleSuggestion, "마감")
    }

    func testRecognizesRangeWithTimesAtBothEndpoints() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment(
                "행사 2026-09-14 09:00 ~ 2026-09-21 18:00",
                y: 0.6
            )],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.rangeRole), [.start, .end])
        XCTAssertEqual(drafts.map(\.time), [
            ClockTime(hour: 9, minute: 0),
            ClockTime(hour: 18, minute: 0),
        ])
    }

    func testMarksBackwardInheritedRangeAsAmbiguousWithoutRollingYearForward() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("휴가 2026.12.31 ~ 01.02", y: 0.6)],
            captureDate: makeDate(2026, 12, 1),
            analysisDate: makeDate(2026, 12, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.date), [
            CalendarDate(year: 2026, month: 12, day: 31),
            CalendarDate(year: 2026, month: 1, day: 2),
        ])
        XCTAssertEqual(drafts[1].reviewReasons, [.ambiguousRange])
    }

    func testUsesCandidateLocalTitlesEvidenceAndLocationsWithinOneFragment() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment(
                "회의 2026-09-21 10:00, 진료 2026-09-22 11:00",
                y: 0.6
            )],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.titleSuggestion), ["회의", "진료"])
        XCTAssertEqual(drafts.map(\.evidenceText), [
            "회의 2026-09-21 10:00",
            "진료 2026-09-22 11:00",
        ])
        XCTAssertLessThan(drafts[0].evidenceLocation.x, drafts[1].evidenceLocation.x)
    }

    func testAssociatesAdjacentTimeBeforeDateWithinOneClause() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment("회의 14:00 2026-09-21", y: 0.6)],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].date, CalendarDate(year: 2026, month: 9, day: 21))
        XCTAssertEqual(drafts[0].time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(drafts[0].reviewReasons, [.timeZoneInferred])
    }

    func testUsesMiddleDotAsCandidateContextBoundary() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment(
                "회의 2026-09-21 10:00 · 진료 2026-09-22 11:00",
                y: 0.6
            )],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.titleSuggestion), ["회의", "진료"])
        XCTAssertEqual(drafts.map(\.evidenceText), [
            "회의 2026-09-21 10:00",
            "진료 2026-09-22 11:00",
        ])
    }

    func testRecognizesTimedRangeWhenStartEndpointHasTimeZone() {
        let drafts = DateTimeParser().parse(
            fragments: [fragment(
                "2026-09-14 09:00 KST ~ 2026-09-21 18:00 KST",
                y: 0.6
            )],
            captureDate: nil,
            analysisDate: makeDate(2026, 9, 1),
            timeZone: seoul
        )

        XCTAssertEqual(drafts.map(\.rangeRole), [.start, .end])
        XCTAssertEqual(drafts.map(\.timeZoneIdentifier), ["Asia/Seoul", "Asia/Seoul"])
    }

    func testOutputAndSourceKeyMaterialAreDeterministic() {
        let fragments = [fragment("회의 2026-09-21 14:00", y: 0.6)]
        let parser = DateTimeParser()

        let first = parser.parse(
            fragments: fragments,
            captureDate: makeDate(2026, 9, 20),
            analysisDate: makeDate(2026, 9, 21),
            timeZone: seoul
        )
        let second = parser.parse(
            fragments: fragments,
            captureDate: makeDate(2026, 9, 20),
            analysisDate: makeDate(2026, 9, 21),
            timeZone: seoul
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first[0].sourceKeyMaterial.isEmpty)
    }

    func testEnglishMeridiemConvertsTwelveHourClockAndNeverBecomesTitle() throws {
        let cases: [(String, ClockTime)] = [
            ("2:00 PM", ClockTime(hour: 14, minute: 0)),
            ("2:00 AM", ClockTime(hour: 2, minute: 0)),
            ("12:00 AM", ClockTime(hour: 0, minute: 0)),
            ("12:00 PM", ClockTime(hour: 12, minute: 0)),
            ("11:59 pm", ClockTime(hour: 23, minute: 59)),
            ("2:00 p.m.", ClockTime(hour: 14, minute: 0)),
            ("AM 12:15", ClockTime(hour: 0, minute: 15)),
            ("오후 2:00", ClockTime(hour: 14, minute: 0)),
            ("오전 12:00", ClockTime(hour: 0, minute: 0)),
            ("오후 2시", ClockTime(hour: 14, minute: 0)),
        ]
        for (text, expected) in cases {
            let drafts = parse([fragment(text, y: 0.6)])
            let draft = try XCTUnwrap(drafts.first, text)
            XCTAssertEqual(drafts.count, 1, text)
            XCTAssertEqual(draft.time, expected, text)
            XCTAssertEqual(draft.titleSuggestion, "일정 확인 필요", text)
            XCTAssertTrue(draft.reviewReasons.contains(.missingTitle), text)
        }
    }

    func testSplitMeridiemOnSameRowBelongsToTimeRegardlessOfFragmentOrder() throws {
        let time = fragment("2026-10-03 2:00", x: 0.1, y: 0.6, width: 0.5, height: 0.04)
        let pm = fragment("PM", x: 0.62, y: 0.603, width: 0.07, height: 0.035)
        for fragments in [[time, pm], [pm, time]] {
            let drafts = parse(fragments)
            let draft = try XCTUnwrap(drafts.first)
            XCTAssertEqual(drafts.count, 1)
            XCTAssertEqual(draft.time, ClockTime(hour: 14, minute: 0))
            XCTAssertEqual(draft.titleSuggestion, "일정 확인 필요")
            XCTAssertTrue(draft.evidenceText.contains("PM"))
        }
    }

    func testMeridiemDoesNotCrossRowsColumnsOrCandidateBoundaries() {
        let drafts = parse([
            fragment("Call 2026-10-03 2:00 PM, Lunch 2026-10-04 12:00 AM", y: 0.8),
            fragment("2026-10-05 2:00", x: 0.1, y: 0.5, width: 0.35, height: 0.04),
            fragment("PM", x: 0.8, y: 0.5, width: 0.1, height: 0.04),
            fragment("PM", x: 0.1, y: 0.3, width: 0.1, height: 0.04),
        ])
        XCTAssertEqual(drafts.map(\.time), [
            ClockTime(hour: 14, minute: 0), ClockTime(hour: 0, minute: 0),
            ClockTime(hour: 2, minute: 0),
        ])
        XCTAssertEqual(drafts.map(\.titleSuggestion), ["Call", "Lunch", "일정 확인 필요"])
    }

    func testNearbyThreeLineContextPreservesTitleAndPlaceInExistingDraftContract() throws {
        let draft = try XCTUnwrap(parse([
            fragment("실기기 테스트 회의", y: 0.7, height: 0.04),
            fragment("2026년 10월 3일 오후 2시", y: 0.63, height: 0.04),
            fragment("강남역", y: 0.56, height: 0.04),
        ]).first)
        XCTAssertEqual(draft.titleSuggestion, "실기기 테스트 회의 · 강남역")
        XCTAssertEqual(draft.date, CalendarDate(year: 2026, month: 10, day: 3))
        XCTAssertEqual(draft.time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(draft.evidenceText, "실기기 테스트 회의\n2026년 10월 3일 오후 2시\n강남역")
        XCTAssertEqual(draft.reviewReasons, [.timeZoneInferred])
        XCTAssertEqual(draft.evidenceLocation.y, 0.56, accuracy: 0.0001)
        XCTAssertEqual(draft.evidenceLocation.height, 0.18, accuracy: 0.0001)
    }

    func testContextDoesNotGuessFromDistantLowConfidenceOrAmbiguousLines() {
        let date = fragment("2026-10-03 14:00", y: 0.5, height: 0.04)
        let lowConfidence = RecognizedTextFragment(
            text: "회의", boundingBox: CGRect(x: 0.1, y: 0.57, width: 0.5, height: 0.04),
            confidence: 0.1
        )
        let inputs = [
            [fragment("회의", y: 0.85, height: 0.04), date],
            [lowConfidence, date],
            [fragment("회의", x: 0.75, y: 0.57, width: 0.2, height: 0.04),
             fragment("2026-10-03 14:00", x: 0.1, y: 0.5, width: 0.4, height: 0.04)],
            [fragment("회의", y: 0.57, height: 0.04),
             fragment("다른 행사", y: 0.575, height: 0.04), date],
        ]
        for input in inputs {
            let drafts = parse(input)
            XCTAssertEqual(drafts.first?.titleSuggestion, "일정 확인 필요")
            XCTAssertTrue(drafts.first?.reviewReasons.contains(.missingTitle) == true)
        }
    }

    func testClockWithoutSpaceAfterTitleStillParsesAndEmbeddedAMIsNotAMarker() {
        let drafts = parse([
            fragment("회의14:00 2026-10-03", y: 0.8),
            fragment("SPAM 2:00 2026-10-04", y: 0.6),
        ])
        XCTAssertEqual(drafts.map(\.time), [ClockTime(hour: 14, minute: 0), ClockTime(hour: 2, minute: 0)])
        XCTAssertEqual(drafts.map(\.titleSuggestion), ["회의", "SPAM"])
    }

    func testSplitKoreanMeridiemAfterClockDoesNotPolluteTitle() {
        for (marker, hour) in [("오후", 14), ("오전", 2)] {
            let drafts = parse([
                fragment("2026-10-03 2:00", x: 0.1, y: 0.6, width: 0.5, height: 0.04),
                fragment(marker, x: 0.62, y: 0.6, width: 0.1, height: 0.04),
            ])
            XCTAssertEqual(drafts.first?.time, ClockTime(hour: hour, minute: 0))
            XCTAssertEqual(drafts.first?.titleSuggestion, "일정 확인 필요")
            XCTAssertTrue(drafts.first?.reviewReasons.contains(.missingTitle) == true)
        }
    }

    func testPlaceOrFormLabelAboveDateDoesNotEstablishAnEventTitle() {
        for text in ["강남역", "장소: 강남역", "Date", "날짜"] {
            let drafts = parse([
                fragment(text, y: 0.7, height: 0.04),
                fragment("2026-10-03 14:00", y: 0.63, height: 0.04),
            ])
            XCTAssertEqual(drafts.first?.titleSuggestion, "일정 확인 필요", text)
            XCTAssertTrue(drafts.first?.reviewReasons.contains(.missingTitle) == true, text)
            if text.contains("강남역") {
                XCTAssertTrue(drafts.first?.evidenceText.contains("강남역") == true)
            }
        }
    }

    func testLargeTitleIsOwnedOnlyByNearestDateDespiteSmallShiftedDateRows() {
        let drafts = parse([
            fragment("공동 회의", x: 0.11, y: 0.68, width: 0.5, height: 0.08),
            fragment("2026-10-03 14:00", x: 0.1, y: 0.635, width: 0.5, height: 0.02),
            fragment("2026-10-04 14:00", x: 0.125, y: 0.58, width: 0.5, height: 0.02),
        ])
        XCTAssertEqual(drafts.map(\.titleSuggestion), ["공동 회의", "일정 확인 필요"])
        XCTAssertFalse(drafts[0].reviewReasons.contains(.missingTitle))
        XCTAssertTrue(drafts[1].reviewReasons.contains(.missingTitle))
    }

    // Catches greedy allocation to the last unassigned date, and loss of unpaired times.
    func testListedDatesAndTimesKeepDatesWithoutGuessingPairingInThreeLanguages() {
        for title in ["회의", "Meeting", "会議"] {
            for dates in ["10/8 10/9", "2026-10-08 2026-10-09"] {
                let text = "\(title) \(dates) 09:00 14:00"
                let dated = parse([fragment(text,y:0.6)]).filter { $0.date != nil }
                XCTAssertEqual(dated.map(\.date),[CalendarDate(year:2026,month:10,day:8),CalendarDate(year:2026,month:10,day:9)],text)
                XCTAssertTrue(dated.allSatisfy {$0.time == nil && $0.timeZoneIdentifier == nil},text)
                XCTAssertTrue(dated.allSatisfy {$0.reviewReasons.map(\.rawValue).contains("uncertainTimeAssociation")},text)
                XCTAssertTrue(dated.allSatisfy {$0.evidenceText.contains("09:00") && $0.evidenceText.contains("14:00")},text)
                XCTAssertEqual(dated.map(\.titleSuggestion),[title,title])
            }
        }
    }

    // Catches silently dropping the range end at CandidateCreationService's dated-only boundary.
    func testSingleDateTimeRangeRequiresExplicitSingleTimeStorageReviewInThreeLanguages() {
        for title in ["회의", "Meeting", "会議"] {
            for separator in ["~","〜","–","-","～"] {
                let text = "\(title) 2026-10-08 09:00\(separator)18:00"
                let dated = parse([fragment(text,y:0.6)]).filter {$0.date != nil}
                XCTAssertEqual(dated.count,1,text)
                XCTAssertEqual(dated.first?.time,ClockTime(hour:9,minute:0),text)
                XCTAssertTrue(dated.first?.reviewReasons.map(\.rawValue).contains("timeRangeNotStored") == true,text)
                XCTAssertTrue(dated.first?.evidenceText.contains("18:00") == true,text)
            }
        }
    }

    func testSeparatedEventsKeepTheirOwnTitleDateTimeAndEvidenceInThreeLanguages() {
        for (a,b,separator) in [("회의","면접",","),("Meeting","Interview",","),("会議","面接","、")] {
            let drafts=parse([fragment("\(a) 10/8 09:00\(separator) \(b) 10/9 14:00",y:0.6)])
            XCTAssertEqual(drafts.map(\.titleSuggestion),[a,b])
            XCTAssertEqual(drafts.map(\.date),[CalendarDate(year:2026,month:10,day:8),CalendarDate(year:2026,month:10,day:9)])
            XCTAssertEqual(drafts.map(\.time),[ClockTime(hour:9,minute:0),ClockTime(hour:14,minute:0)])
            XCTAssertEqual(drafts.map(\.evidenceText),["\(a) 10/8 09:00","\(b) 10/9 14:00"])
            if drafts.count == 2 {XCTAssertLessThan(drafts[0].evidenceLocation.x,drafts[1].evidenceLocation.x)}
        }
    }

    func testDateRangeEndpointTimesAndEndOnlyTimeKeepExistingContractInThreeLanguages() {
        for title in ["회의", "Meeting", "会議"] {
            let both=parse([fragment("\(title) 2026-10-08 09:00 KST ~ 10/9 18:00 KST",y:0.6)])
            XCTAssertEqual(both.map(\.rangeRole),[.start,.end]);XCTAssertEqual(both.map(\.time),[ClockTime(hour:9,minute:0),ClockTime(hour:18,minute:0)])
            XCTAssertEqual(both.map(\.reviewReasons),[[],[]])
            let endOnly=parse([fragment("\(title) 2026-10-08 ~ 10/9 18:00 KST",y:0.6)])
            XCTAssertEqual(endOnly.map(\.rangeRole),[.start,.end]);XCTAssertNil(endOnly.first?.time)
            XCTAssertEqual(endOnly.last?.time,ClockTime(hour:18,minute:0))
            XCTAssertEqual(endOnly.map(\.reviewReasons),[[],[]])
        }
    }

    func testMultipleUnrangedTimesAndLeadingListsAreNotSilentlyAssigned() {
        for text in ["Meeting 2026-10-08 09:00 14:00", "Meeting 09:00 14:00 2026-10-08", "Meeting 09:00 14:00 2026-10-08 2026-10-09"] {
            let dated=parse([fragment(text,y:0.6)]).filter {$0.date != nil}
            XCTAssertFalse(dated.isEmpty)
            XCTAssertTrue(dated.allSatisfy {$0.time == nil},text)
            XCTAssertTrue(dated.allSatisfy {$0.reviewReasons.map(\.rawValue).contains("uncertainTimeAssociation")},text)
        }
    }

    func testAmbiguousTimeEvidenceKeepsLateExpressionsAndIndependentDatePairing() {
        let text="Meeting " + String(repeating:"context ",count:24) + "2026-10-08 2026-10-09 09:00 14:00"
        let dated=parse([fragment(text,y:0.6)]).filter {$0.date != nil}
        XCTAssertEqual(dated.count,2)
        XCTAssertTrue(dated.allSatisfy {$0.evidenceText.contains("09:00") && $0.evidenceText.contains("14:00")})
        let independent=parse([fragment("Meeting 2026-10-07 08:00 KST / Work 2026-10-08 2026-10-09 09:00 14:00",y:0.6)]).filter {$0.date != nil}
        XCTAssertEqual(independent.first?.time,ClockTime(hour:8,minute:0))
        XCTAssertEqual(independent.first?.reviewReasons,[])
        XCTAssertTrue(independent.dropFirst().allSatisfy {$0.time == nil && $0.requiresReview})
    }

    func testTimeRangeWithExplicitZonesStillKeepsStartAndReportsUnstoredEnd() {
        let dated=parse([fragment("Meeting 2026-10-08 09:00 KST ~ 18:00 KST",y:0.6)]).filter {$0.date != nil}
        XCTAssertEqual(dated.count,1)
        XCTAssertEqual(dated.first?.time,ClockTime(hour:9,minute:0))
        XCTAssertEqual(dated.first?.timeZoneIdentifier,"Asia/Seoul")
        XCTAssertEqual(dated.first?.reviewReasons.map(\.rawValue),["timeRangeNotStored"])
    }

    func testUnpairedTimesImmediatelyBeforeAnotherDateRequireReviewOnBothDates() {
        for text in ["Meeting 2026-10-08 09:00 14:00 2026-10-09", "Meeting 2026-10-08 09:00 14:00 2026-10-09 18:00", "Meeting 2026-10-08 09:00 14:00 2026-10-09 2026-10-10"] {
            let dated=parse([fragment(text,y:0.6)]).filter {$0.date != nil}
            XCTAssertTrue(dated.allSatisfy {$0.time == nil && $0.reviewReasons.map(\.rawValue).contains("uncertainTimeAssociation")},text)
        }
    }

    func testMetadataHeadingWithPlaceContextRemainsReviewableInThreeLanguages() {
        for title in ["작성일", "Published", "投稿日"] {
            let dated=parse([fragment(title,y:0.7,height:0.04),fragment("2026-10-08 09:00 KST",y:0.63,height:0.04),fragment("Location: Hall",y:0.56,height:0.04)])
            XCTAssertEqual(dated.count,1)
            XCTAssertTrue(dated.first?.reviewReasons.map(\.rawValue).contains("possibleMetadataDate") == true,title)
            XCTAssertTrue(dated.first?.evidenceText.contains(title) == true,title)
        }
    }

    func testNonAdjacentLeadingClockKeepsDateAndRequiresPairingReview() {
        for title in ["회의", "Meeting", "会議"] {
            let text="09:00 \(title) 2026-10-08"
            let dated=parse([fragment(text,y:0.6)]).filter {$0.date != nil}
            XCTAssertEqual(dated.count,1)
            XCTAssertNil(dated.first?.time)
            XCTAssertTrue(dated.first?.reviewReasons.map(\.rawValue).contains("uncertainTimeAssociation") == true,text)
            XCTAssertTrue(dated.first?.evidenceText.contains("09:00") == true,text)
        }
        // An acknowledged time range keeps its start when an independent date follows.
        let range=parse([fragment("Meeting 2026-10-08 09:00~18:00 2026-10-09",y:0.6)]).filter {$0.date != nil}
        XCTAssertEqual(range.first?.time,ClockTime(hour:9,minute:0))
        XCTAssertTrue(range.first?.reviewReasons.map(\.rawValue).contains("timeRangeNotStored") == true)
    }

    private func parse(_ fragments: [RecognizedTextFragment]) -> [DateTimeCandidateDraft] {
        DateTimeParser().parse(
            fragments: fragments, captureDate: nil,
            analysisDate: makeDate(2026, 10, 1), timeZone: seoul
        )
    }

    private func fragment(
        _ text: String,
        x: CGFloat = 0.1,
        y: CGFloat,
        width: CGFloat = 0.8,
        height: CGFloat = 0.08
    ) -> RecognizedTextFragment {
        RecognizedTextFragment(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: 0.9
        )
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
