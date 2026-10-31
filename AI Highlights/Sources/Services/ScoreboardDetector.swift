import CoreGraphics
import Foundation
import Vision

/// Sparse on-device OCR supplements distant/occluded basket detections. Text
/// recognition is optional: a failure or absent overlay never fails video analysis.
final class ScoreboardDetector {
    private let request: VNRecognizeTextRequest
    private let enhancedRequest: VNRecognizeTextRequest

    init() {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.025
        // The installed profile cannot run background GPU work.
        request.usesCPUOnly = true
        self.request = request
        let enhancedRequest = VNRecognizeTextRequest()
        enhancedRequest.recognitionLevel = .accurate
        enhancedRequest.usesLanguageCorrection = false
        enhancedRequest.recognitionLanguages = ["en-US"]
        enhancedRequest.minimumTextHeight = 0.012
        enhancedRequest.usesCPUOnly = true
        self.enhancedRequest = enhancedRequest
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
        let tokens = tokens(from: request.results)
        if let reading = ScoreboardParser.reading(from: tokens) { return reading }

        // Low-resolution overlays often yield HOME/GUEST but lose the small
        // seven-segment digits. Enlarge the board region and run OCR again.
        let labels = tokens.filter { ["HOME", "GUEST"].contains($0.text.uppercased()) }
        guard let left = labels.min(by: { $0.midX < $1.midX }),
              let right = labels.max(by: { $0.midX < $1.midX }), left.midX < right.midX else { return nil }
        let cropX = max(0, (left.x - left.width * 0.2) * CGFloat(band.width))
        let cropRight = min(CGFloat(band.width), (right.x + right.width * 1.2) * CGFloat(band.width))
        let cropY = max(0, (left.y - left.height * 0.35) * CGFloat(band.height))
        let cropRect = CGRect(x: cropX, y: cropY, width: max(1, cropRight - cropX),
                              height: max(1, CGFloat(band.height) - cropY)).integral
        guard let board = band.cropping(to: cropRect),
              let enlarged = enlarged(board, scale: 4) else { return nil }
        do { try VNImageRequestHandler(cgImage: enlarged, orientation: .up).perform([enhancedRequest]) }
        catch { return nil }
        let enhanced = tokens(from: enhancedRequest.results).map { token in
            ScoreboardParser.Token(text: token.text, confidence: token.confidence,
                x: (Double(cropRect.minX) + token.x * Double(cropRect.width)) / Double(band.width),
                y: (Double(cropRect.minY) + token.y * Double(cropRect.height)) / Double(band.height),
                width: token.width * Double(cropRect.width) / Double(band.width),
                height: token.height * Double(cropRect.height) / Double(band.height))
        }
        return ScoreboardParser.reading(from: enhanced)
    }

    private func tokens(from observations: [VNRecognizedTextObservation]?) -> [ScoreboardParser.Token] {
        (observations ?? []).compactMap { observation -> ScoreboardParser.Token? in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ScoreboardParser.Token(text: text.string, confidence: Double(text.confidence),
                                          x: box.minX, y: box.minY, width: box.width, height: box.height)
        }
    }

    private func enlarged(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
