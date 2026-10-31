import CoreGraphics
import Foundation
import Vision

/// Sparse on-device OCR supplements distant/occluded basket detections. Text
/// recognition is optional: a failure or absent overlay never fails video analysis.
final class ScoreboardDetector {
    private let request: VNRecognizeTextRequest

    init() {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.025
        // The installed profile cannot run background GPU work.
        request.usesCPUOnly = true
        self.request = request
    }

    func reading(in image: CGImage) -> ScoreboardReading? {
        // CGImage cropping uses top-left image coordinates. Vision observations
        // within this band use bottom-left normalized coordinates.
        let bandHeight = max(1, Int(Double(image.height) * 0.30))
        let rect = CGRect(x: 0, y: CGFloat(image.height - bandHeight),
                          width: CGFloat(image.width), height: CGFloat(bandHeight))
        guard let band = image.cropping(to: rect) else { return nil }
        do { try VNImageRequestHandler(cgImage: band, orientation: .up).perform([request]) }
        catch { return nil }
        let tokens = (request.results ?? []).compactMap { observation -> ScoreboardParser.Token? in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ScoreboardParser.Token(text: text.string, confidence: Double(text.confidence),
                                          x: box.minX, y: box.minY, width: box.width, height: box.height)
        }
        return ScoreboardParser.reading(from: tokens)
    }
}
