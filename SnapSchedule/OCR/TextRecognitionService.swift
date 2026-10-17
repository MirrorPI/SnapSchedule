import CoreGraphics
import Foundation
import Vision

struct RecognizedTextFragment: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

enum TextRecognitionError: Error, Equatable, Sendable {
    case cancelled
    case failed(domain: String, code: Int)
}

struct TextRecognitionWork: @unchecked Sendable {
    let perform: @Sendable () throws -> [RecognizedTextFragment]
    let cancel: @Sendable () -> Void
}

final class TextRecognitionService: Sendable {
    typealias WorkFactory = @Sendable (ScreenshotImageInput) -> TextRecognitionWork

    private let makeWork: WorkFactory

    init(makeWork: @escaping WorkFactory) {
        self.makeWork = makeWork
    }

    convenience init() {
        self.init { input in
            let operation = VisionTextRecognitionOperation(input: input)
            return TextRecognitionWork(
                perform: { try operation.perform() },
                cancel: { operation.cancel() }
            )
        }
    }

    func recognize(
        _ input: ScreenshotImageInput
    ) async throws -> [RecognizedTextFragment] {
        let work = makeWork(input)
        let worker = Task.detached(priority: .userInitiated) {
            try work.perform()
        }

        do {
            let fragments = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
                work.cancel()
            }
            try Task.checkCancellation()
            return Self.readingOrder(fragments)
        } catch is CancellationError {
            throw TextRecognitionError.cancelled
        } catch {
            if Task.isCancelled {
                throw TextRecognitionError.cancelled
            }
            if let error = error as? TextRecognitionError {
                throw error
            }
            let error = error as NSError
            throw TextRecognitionError.failed(domain: error.domain, code: error.code)
        }
    }

    private static func readingOrder(
        _ fragments: [RecognizedTextFragment]
    ) -> [RecognizedTextFragment] {
        fragments.sorted { left, right in
            let leftTop = left.boundingBox.maxY
            let rightTop = right.boundingBox.maxY
            if leftTop != rightTop {
                return leftTop > rightTop
            }

            let leftLeading = left.boundingBox.minX
            let rightLeading = right.boundingBox.minX
            if leftLeading != rightLeading {
                return leftLeading < rightLeading
            }

            if left.boundingBox.height != right.boundingBox.height {
                return left.boundingBox.height > right.boundingBox.height
            }
            return left.text < right.text
        }
    }
}

private final class VisionTextRecognitionOperation: @unchecked Sendable {
    private static let recognitionLanguages = ["ko-KR", "en-US", "ja-JP"]

    private let request: VNRecognizeTextRequest
    private let handler: VNImageRequestHandler

    init(input: ScreenshotImageInput) {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.recognitionLanguages
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        self.request = request
        handler = VNImageRequestHandler(
            data: input.data,
            orientation: input.orientation,
            options: [:]
        )
    }

    func perform() throws -> [RecognizedTextFragment] {
        try Task.checkCancellation()
        try handler.perform([request])
        try Task.checkCancellation()

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return RecognizedTextFragment(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
    }

    func cancel() {
        request.cancel()
    }
}
