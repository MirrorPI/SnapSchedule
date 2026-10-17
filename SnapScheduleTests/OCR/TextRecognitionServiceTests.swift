import CoreGraphics
import ImageIO
import UIKit
import XCTest
@testable import SnapSchedule

@MainActor
final class TextRecognitionServiceTests: XCTestCase {

    func testOversizedOCRResultThrowsInsteadOfReturningAPartialRecognition() async {
        let cases = [
            [RecognizedTextFragment(text: String(repeating: "x", count: 8_001), boundingBox: .zero, confidence: 1)],
            (0..<257).map { _ in RecognizedTextFragment(text: "date", boundingBox: .zero, confidence: 1) },
        ]
        for fragments in cases {
            let service = TextRecognitionService { _ in
                TextRecognitionWork(perform: { fragments }, cancel: {})
            }
            do {
                _ = try await service.recognize(ScreenshotImageInput(data: Data(), orientation: .up))
                XCTFail("Oversized recognition must be rejected, not truncated")
            } catch {
                XCTAssertEqual(String(describing: error), "inputTooLarge")
            }
        }
    }

    func testOversizedEncodedImageIsRejectedBeforeCreatingVisionWork() async {
        let service = TextRecognitionService { _ in
            XCTFail("Oversized bytes must not reach image decoder or Vision work construction")
            return TextRecognitionWork(perform: { [] }, cancel: {})
        }
        do {
            _ = try await service.recognize(ScreenshotImageInput(
                data: Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1), orientation: .up))
            XCTFail("Oversized image must be rejected")
        } catch {
            XCTAssertEqual(String(describing: error), "inputTooLarge")
        }
    }
    func testRecognitionRunsOffMainThreadAndReturnsStableReadingOrder() async throws {
        let lowerRight = RecognizedTextFragment(
            text: "third",
            boundingBox: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.1),
            confidence: 0.7
        )
        let upperRight = RecognizedTextFragment(
            text: "second",
            boundingBox: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.1),
            confidence: 0.8
        )
        let upperLeft = RecognizedTextFragment(
            text: "first",
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1),
            confidence: 0.9
        )
        let service = TextRecognitionService { _ in
            TextRecognitionWork(
                perform: {
                    XCTAssertFalse(Thread.isMainThread)
                    return [lowerRight, upperRight, upperLeft]
                },
                cancel: {}
            )
        }

        let fragments = try await service.recognize(
            ScreenshotImageInput(data: Data([0x01]), orientation: .left)
        )

        XCTAssertEqual(fragments, [upperLeft, upperRight, lowerRight])
    }

    func testEmptyRecognitionIsAValidResult() async throws {
        let service = TextRecognitionService { _ in
            TextRecognitionWork(perform: { [] }, cancel: {})
        }

        let fragments = try await service.recognize(
            ScreenshotImageInput(data: Data(), orientation: .up)
        )

        XCTAssertEqual(fragments, [])
    }

    func testRecognitionFailurePreservesErrorIdentity() async {
        let service = TextRecognitionService { _ in
            TextRecognitionWork(
                perform: {
                    throw NSError(domain: "TextRecognitionTests", code: 41)
                },
                cancel: {}
            )
        }

        do {
            _ = try await service.recognize(
                ScreenshotImageInput(data: Data(), orientation: .up)
            )
            XCTFail("Expected recognition failure")
        } catch {
            XCTAssertEqual(
                error as? TextRecognitionError,
                .failed(domain: "TextRecognitionTests", code: 41)
            )
        }
    }

    func testTaskCancellationCancelsRecognitionWorkAndThrowsCancelled() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let wasCancelled = LockedOCRBox(false)
        let service = TextRecognitionService { _ in
            TextRecognitionWork(
                perform: {
                    started.signal()
                    release.wait()
                    try Task.checkCancellation()
                    return []
                },
                cancel: {
                    wasCancelled.withValue { $0 = true }
                    release.signal()
                }
            )
        }
        let task = Task {
            try await service.recognize(
                ScreenshotImageInput(data: Data(), orientation: .up)
            )
        }

        let startResult = await waitForOCRSemaphore(started, timeout: .now() + 1)
        XCTAssertEqual(startResult, .success)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .cancelled)
        }
        XCTAssertTrue(wasCancelled.withValue { $0 })
    }

    func testVisionMultipleDatesAndTimeRangesReachParserInThreeLanguages() async throws {
        let zone=TimeZone(identifier:"Asia/Seoul")!
        for title in ["회의", "Meeting", "会議"] {
            let cases=["\(title) 10/8 09:00, Interview 10/9 14:00", "\(title) 10/8 10/9 09:00 14:00", "\(title) 10/8 09:00~18:00", "\(title) 10/8 09:00~10/9 18:00"]
            for (i,text) in cases.enumerated() {
                let fragments=try await TextRecognitionService().recognize(syntheticInput(lines:[text],fontSize:54,width:2000,monospaced:true))
                print("Multiple date/time actual Vision",text,fragments)
                let drafts=DateTimeParser().parse(fragments:fragments,captureDate:nil,analysisDate:Date(timeIntervalSince1970:1791334800),timeZone:zone).filter {$0.date != nil}
                XCTAssertEqual(drafts.count,i == 2 ? 1:2,text)
                XCTAssertEqual(drafts.map {$0.date?.day},i == 2 ? [8]:[8,9],text)
                if i == 1 {
                    XCTAssertTrue(drafts.allSatisfy {$0.time == nil && $0.reviewReasons.map(\.rawValue).contains("uncertainTimeAssociation")},text)
                    XCTAssertTrue(drafts.allSatisfy {$0.evidenceText.contains("09:00") && $0.evidenceText.contains("14:00")},text)
                } else {
                    XCTAssertEqual(drafts.map(\.time),i == 2 ? [ClockTime(hour:9,minute:0)]:[ClockTime(hour:9,minute:0),ClockTime(hour:i == 0 ? 14:18,minute:0)],text)
                    if i == 2 {XCTAssertTrue(drafts.first?.reviewReasons.map(\.rawValue).contains("timeRangeNotStored") == true,text)}
                    if i == 3 {XCTAssertEqual(drafts.map(\.rangeRole),[.start,.end],text)}
                    if i == 0 {
                        XCTAssertEqual(drafts.map(\.titleSuggestion),[title,"Interview"],text)
                        XCTAssertTrue(drafts.first?.evidenceText.contains("10/9") == false,text)
                    }
                }
            }
        }
    }

    func testVisionPlainBusinessDatesReachParserInAllThreeLanguages() async throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Seoul")!
        let capture=calendar.date(from:DateComponents(year:2026,month:9,day:30,hour:12))!
        let analysis=calendar.date(from:DateComponents(year:2026,month:10,day:7,hour:12))!
        for (text,day) in [("수요일 보고서 제출",7),("Submit the report Wednesday",7),("水曜日に報告書を提出",7),
                           ("8일 보고서 제출",8),("Submit the report on the 8th",8),("8日に報告書を提出",8)] {
            let fragments=try await TextRecognitionService().recognize(syntheticInput(lines:[text]))
            print("Plain business OCR",text,fragments.map(\.text))
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:capture,analysisDate:analysis,timeZone:calendar.timeZone)
            XCTAssertEqual(drafts.count,1,text)
            XCTAssertEqual(drafts.first?.date,CalendarDate(year:2026,month:10,day:day),text)
            XCTAssertNil(drafts.first?.time); XCTAssertNil(drafts.first?.timeZoneIdentifier)
            XCTAssertTrue(drafts.first?.requiresReview == true)
        }
    }

    func testVisionDeadlineMessagesReachParserInAllThreeLanguages() async throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Seoul")!
        let capture=calendar.date(from:DateComponents(year:2026,month:9,day:30,hour:12))!
        let analysis=calendar.date(from:DateComponents(year:2026,month:10,day:7,hour:12))!
        for (text,day) in [("수요일까지 보고서를 보내주세요",7),("Please send the report by Wednesday",7),("水曜日までに報告書を送ってください",7),("8일까지 보고서를 보내주세요",8),("Please send the report by the 8th",8),("8日までに報告書を送ってください",8)] {
            let fragments=try await TextRecognitionService().recognize(syntheticInput(lines:[text]))
            print("Deadline OCR",text,fragments.map(\.text))
            let drafts=DateTimeParser().parse(fragments:fragments,captureDate:capture,analysisDate:analysis,timeZone:calendar.timeZone).filter {$0.date != nil}
            XCTAssertEqual(drafts.count,1,text)
            XCTAssertEqual(drafts.first?.date,CalendarDate(year:2026,month:10,day:day),text)
        }
    }

    func testVisionRecognizesKoreanScheduleDateAndTime() async throws {
        let input = try syntheticInput(
            lines: ["채용 면접 일정", "2026년 9월 28일 오후 3시"]
        )

        let fragments = try await TextRecognitionService().recognize(input)
        let text = fragments.map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("2026"), text)
        XCTAssertTrue(text.contains("9"), text)
        XCTAssertTrue(text.contains("28"), text)
        XCTAssertTrue(text.contains("3"), text)
        assertValidResultStructure(fragments)
    }

    func testVisionRecognizesEnglishReservationDateAndTime() async throws {
        let input = try syntheticInput(
            lines: ["DINNER RESERVATION", "September 30, 2026 at 7:30 PM"]
        )

        let fragments = try await TextRecognitionService().recognize(input)
        let text = fragments.map(\.text).joined(separator: " ")

        XCTAssertTrue(text.localizedCaseInsensitiveContains("September"), text)
        XCTAssertTrue(text.contains("30"), text)
        XCTAssertTrue(text.contains("2026"), text)
        XCTAssertTrue(text.contains("7:30"), text)
        assertValidResultStructure(fragments)
    }

    func testVisionRecognizesSmallScheduleText() async throws {
        let input = try syntheticInput(
            lines: ["Workshop 2026-10-02 09:15"],
            fontSize: 24
        )

        let fragments = try await TextRecognitionService().recognize(input)
        let text = fragments.map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("2026"), text)
        XCTAssertTrue(text.contains("10"), text)
        XCTAssertTrue(text.contains("02"), text)
        XCTAssertTrue(text.contains("09:15"), text)
    }

    func testVisionUsesImageOrientationForRotatedScheduleText() async throws {
        let upright = try syntheticImage(
            lines: ["APPOINTMENT 2026-10-04 11:20 AM"]
        )
        let rotatedData = try XCTUnwrap(
            UIImage(cgImage: upright, scale: 1, orientation: .left).pngData()
        )
        let input = ScreenshotImageInput(data: rotatedData, orientation: .right)

        let fragments = try await TextRecognitionService().recognize(input)
        let text = fragments.map(\.text).joined(separator: " ")

        XCTAssertTrue(text.contains("2026"), text)
        XCTAssertTrue(text.contains("10"), text)
        XCTAssertTrue(text.contains("04"), text)
        XCTAssertTrue(text.contains("11:20"), text)
    }

    func testVisionReturnsEmptyForSyntheticImageWithoutText() async throws {
        let input = try syntheticInput(lines: [])

        let fragments = try await TextRecognitionService().recognize(input)

        XCTAssertEqual(fragments, [])
    }

    func testVisionThreeLineContextReachesParserWithoutLosingTitleOrPlace() async throws {
        let input = try syntheticInput(lines: [
            "실기기 테스트 회의", "2026년 10월 3일 오후 2시", "강남역",
        ])
        let fragments = try await TextRecognitionService().recognize(input)
        let text = fragments.map(\.text).joined(separator: "\n")
        print("Task28 OCR three-line fragments: \(fragments)")
        XCTAssertTrue(text.contains("실기기 테스트 회의"), "OCR title omission: \(text)")
        XCTAssertTrue(text.contains("강남역"), "OCR place omission: \(text)")
        let drafts = DateTimeParser().parse(
            fragments: fragments, captureDate: nil,
            analysisDate: .now, timeZone: TimeZone(identifier: "Asia/Seoul")!
        )
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(draft.titleSuggestion, "실기기 테스트 회의 · 강남역", "Parser context loss: \(text)")
        XCTAssertEqual(draft.time, ClockTime(hour: 14, minute: 0))
        XCTAssertTrue(draft.evidenceText.contains("강남역"))
    }

    func testVisionEnglishPMReachesParserAsAfternoonWithoutTitlePollution() async throws {
        let fragments = try await TextRecognitionService().recognize(
            syntheticInput(lines: ["2026-10-03 2:00 PM"])
        )
        let text = fragments.map(\.text).joined(separator: "\n")
        print("Task28 OCR PM fragments: \(fragments)")
        XCTAssertTrue(text.contains("PM"), "OCR meridiem omission: \(text)")
        let draft = try XCTUnwrap(DateTimeParser().parse(
            fragments: fragments, captureDate: nil,
            analysisDate: .now, timeZone: TimeZone(identifier: "Asia/Seoul")!
        ).first)
        XCTAssertEqual(draft.time, ClockTime(hour: 14, minute: 0))
        XCTAssertEqual(draft.titleSuggestion, "일정 확인 필요")
    }

    private func assertValidResultStructure(
        _ fragments: [RecognizedTextFragment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(fragments.isEmpty, file: file, line: line)
        for fragment in fragments {
            XCTAssertFalse(fragment.text.isEmpty, file: file, line: line)
            XCTAssertTrue((0...1).contains(fragment.confidence), file: file, line: line)
            XCTAssertTrue(fragment.boundingBox.width > 0, file: file, line: line)
            XCTAssertTrue(fragment.boundingBox.height > 0, file: file, line: line)
        }
    }

    private func syntheticInput(
        lines: [String],
        fontSize: CGFloat = 54,
        width: CGFloat = 1_200,
        monospaced: Bool = false
    ) throws -> ScreenshotImageInput {
        let image = try syntheticImage(lines: lines, fontSize: fontSize, width: width, monospaced: monospaced)
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        return ScreenshotImageInput(data: data, orientation: .up)
    }

    private func syntheticImage(
        lines: [String],
        fontSize: CGFloat = 54,
        width: CGFloat = 1_200,
        monospaced: Bool = false
    ) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: 800),
            format: format
        )
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 800))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: monospaced ? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold) : UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            for (index, text) in lines.enumerated() {
                text.draw(
                    at: CGPoint(x: 80, y: 120 + CGFloat(index) * (fontSize + 40)),
                    withAttributes: attributes
                )
            }
        }
        return try XCTUnwrap(image.cgImage)
    }
}

private func waitForOCRSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

private final class LockedOCRBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
