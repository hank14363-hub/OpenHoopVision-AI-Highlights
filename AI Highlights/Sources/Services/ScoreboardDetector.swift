import CoreGraphics
import CoreImage
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
        let bandPixelHeight = max(1, Int(Double(image.height) * 0.30))
        let rect = CGRect(x: 0, y: CGFloat(image.height - bandPixelHeight),
                          width: CGFloat(image.width), height: CGFloat(bandPixelHeight))
        guard let band = image.cropping(to: rect) else { return nil }
        do { try VNImageRequestHandler(cgImage: band, orientation: .up).perform([request]) }
        catch { return nil }
        let initialTokens = tokens(from: request.results)
        if let reading = ScoreboardParser.reading(from: initialTokens) { return reading }

        // Low-resolution overlays often yield HOME/GUEST but lose the small
        // seven-segment digits. Enlarge the board region and run OCR again.
        let labels = initialTokens.filter { ["HOME", "GUEST"].contains($0.text.uppercased()) }
        guard let left = labels.min(by: { $0.midX < $1.midX }),
              let right = labels.max(by: { $0.midX < $1.midX }), left.midX < right.midX else { return nil }
        let cropX = max(0, (left.x - left.width * 0.2) * CGFloat(band.width))
        let cropRight = min(CGFloat(band.width), (right.x + right.width * 1.2) * CGFloat(band.width))
        // Labels are above the digits. Convert Vision's bottom-left coordinates
        // to CGImage's top-left coordinates, and include everything below them.
        let labelTop = max(left.y + left.height, right.y + right.height)
        let cropY = max(0, (1 - labelTop - max(left.height, right.height) * 0.35) * Double(band.height))
        let cropRect = CGRect(x: cropX, y: cropY, width: max(1, cropRight - cropX),
                              height: max(1, CGFloat(band.height) - cropY)).integral
        guard let board = band.cropping(to: cropRect),
              let enlarged = enlarged(board, scale: 4) else { return nil }
        let variants = [enlarged, adjusted(enlarged, brightness: 0.18, contrast: 1.8)].compactMap { $0 }
        for variant in variants {
            do { try VNImageRequestHandler(cgImage: variant, orientation: .up).perform([enhancedRequest]) }
            catch { continue }
            let enhancedSource = tokens(from: enhancedRequest.results)
            let bandWidth = Double(band.width)
            let bandHeight = Double(band.height)
            let cropMinX = Double(cropRect.minX)
            let cropTop = Double(cropRect.minY)
            let cropWidth = Double(cropRect.width)
            let cropHeight = Double(cropRect.height)
            let enhanced = enhancedSource.map { token -> ScoreboardParser.Token in
                ScoreboardParser.remapped(token, cropX: cropMinX, cropTop: cropTop,
                                          cropWidth: cropWidth, cropHeight: cropHeight,
                                          bandWidth: bandWidth, bandHeight: bandHeight)
            }
            if let reading = ScoreboardParser.reading(from: enhanced) { return reading }
        }
        return nil
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

    private func adjusted(_ image: CGImage, brightness: Double, contrast: Double) -> CGImage? {
        let source = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: 0.2
        ])
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(source, from: source.extent)
    }
}
