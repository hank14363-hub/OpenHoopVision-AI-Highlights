import CoreML
import Foundation
import ImageIO
import Vision

struct BasketDetection: Sendable {
    let confidence: Double
}

enum DetectorError: LocalizedError {
    case missingModel
    case unsupportedInput
    case unsupportedOutput
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return String(localized: "BasketballDetector is missing from the app.", bundle: AppLanguage.current.bundle)
        case .unsupportedInput:
            return String(localized: "BasketballDetector requires a fixed 1280 × 736 RGB image input.", bundle: AppLanguage.current.bundle)
        case .unsupportedOutput:
            return String(localized: "BasketballDetector must return an NMS-free [1, 300, 6] detection output.", bundle: AppLanguage.current.bundle)
        case .invalidImage:
            return String(localized: "Unable to read this video frame.", bundle: AppLanguage.current.bundle)
        }
    }
}

/// Runs the bundled YOLO26 Core ML image model through Vision and reads its NMS-free detections.
/// Vision performs aspect-fit preprocessing; Core ML can use all available compute units and
/// chooses the available hardware per device and OS.
final class CoreMLBasketballDetector {
    private static let detectionCount = 300
    private static let valuesPerDetection = 6

    private let visionModel: VNCoreMLModel
    private let request: VNCoreMLRequest

    /// Let Core ML choose the best available hardware on each device and OS version.
    /// `useGpu` follows Ultralytics' public option name; for Core ML, `true` allows
    /// every compute unit rather than forcing GPU execution.
    private static func computeUnits(useGpu: Bool) -> MLComputeUnits { useGpu ? .all : .cpuOnly }

    init(
        bundle: Bundle = .main,
        modelURL: URL? = nil,
        useGpu: Bool = true
    ) throws {
        guard let modelURL = modelURL ?? bundle.url(forResource: BasketballModel.resourceName, withExtension: "mlmodelc") else {
            throw DetectorError.missingModel
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits(useGpu: useGpu)
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)

        guard let imageInput = model.modelDescription.inputDescriptionsByName.values.first(where: { $0.type == .image })?.imageConstraint,
              imageInput.pixelsWide == BasketballModel.inputWidth,
              imageInput.pixelsHigh == BasketballModel.inputHeight else {
            throw DetectorError.unsupportedInput
        }
        let hasExpectedOutput = model.modelDescription.outputDescriptionsByName.values.contains { description in
            guard description.type == .multiArray,
                  let constraint = description.multiArrayConstraint else { return false }
            return constraint.shape.map(\.intValue) == [1, Self.detectionCount, Self.valuesPerDetection]
        }
        guard hasExpectedOutput else { throw DetectorError.unsupportedOutput }

        let visionModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFit

        self.visionModel = visionModel
        self.request = request
    }

    func detectBallInBasket(in image: CGImage, threshold: Double = AnalysisSettings.defaultThreshold) throws -> BasketDetection? {
        let confidence = try ballInBasketConfidence(in: image)
        guard confidence >= AnalysisSettings.normalizedThreshold(threshold) else { return nil }
        return BasketDetection(confidence: confidence)
    }

    func ballInBasketConfidence(in image: CGImage) throws -> Double {
        BasketSpatialGate.confidence(in: try detections(in: image), imageAspectRatio: Double(image.height) / Double(image.width))
    }

    func detections(in image: CGImage) throws -> [BasketballObject] {
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let fullObjects = try modelObjects(in: image).compactMap {
            BasketImageGeometry.imageObject($0, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        var combined = fullObjects
        // Retain ball observations as well as target labels. A crop can supply
        // a brief ball passage even when the full-frame class-2 score is high.
        let rims = BasketImageGeometry.deduplicated(fullObjects)
            .filter { $0.classID == 1 && $0.confidence >= 0.20 && $0.width <= 0.12 }
            .sorted { $0.confidence > $1.confidence }.prefix(2)
        for rim in rims {
            guard let region = BasketImageGeometry.crop(around: rim, imageWidth: imageWidth, imageHeight: imageHeight) else { continue }
            let rectangle = CGRect(x: region.x * imageWidth, y: region.y * imageHeight,
                                   width: region.width * imageWidth, height: region.height * imageHeight).integral
                .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            guard let cropped = image.cropping(to: rectangle) else { continue }
            let actualRegion = ImageRegion(x: rectangle.minX / imageWidth, y: rectangle.minY / imageHeight,
                                           width: rectangle.width / imageWidth, height: rectangle.height / imageHeight)
            let cropObjects = try modelObjects(in: cropped).compactMap {
                BasketImageGeometry.imageObject($0, imageWidth: Double(cropped.width),
                                                imageHeight: Double(cropped.height), region: actualRegion)
            }
            combined.append(contentsOf: cropObjects)
        }
        return BasketImageGeometry.deduplicated(combined)
    }

    var inputDimensions: [Int] { [1, 3, BasketballModel.inputHeight, BasketballModel.inputWidth] }

    private func modelObjects(in image: CGImage) throws -> [BasketballObject] {
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            throw DetectorError.invalidImage
        }
        guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
              let output = observations.lazy.compactMap({ $0.featureValue.multiArrayValue }).first else {
            throw DetectorError.unsupportedOutput
        }
        return try Self.objects(from: output)
    }

    private static func objects(from output: MLMultiArray) throws -> [BasketballObject] {
        let shape = output.shape.map(\.intValue)
        let strides = output.strides.map(\.intValue)
        guard shape == [1, detectionCount, valuesPerDetection], strides.count == 3 else {
            throw DetectorError.unsupportedOutput
        }

        var objects: [BasketballObject] = []
        for row in 0..<detectionCount {
            let classID = scalar(output, batch: 0, row: row, field: 5, strides: strides)
            guard classID.isFinite, abs(classID.rounded() - classID) < 0.01,
                  classID == 0 || classID == 1 || classID == 2 else { continue }
            let confidence = scalar(output, batch: 0, row: row, field: 4, strides: strides)
            guard confidence.isFinite, confidence >= 0.05, confidence <= 1 else { continue }
            // Verified in this model's MIL graph: anchor - distance = x1y1,
            // anchor + distance = x2y2, then multiplied by the pixel stride.
            objects.append(BasketballObject(classID: Int(classID), confidence: Double(confidence),
                x1: Double(scalar(output, batch: 0, row: row, field: 0, strides: strides)),
                y1: Double(scalar(output, batch: 0, row: row, field: 1, strides: strides)),
                x2: Double(scalar(output, batch: 0, row: row, field: 2, strides: strides)),
                y2: Double(scalar(output, batch: 0, row: row, field: 3, strides: strides))))
        }
        return objects
    }

    private static func scalar(_ array: MLMultiArray, batch: Int, row: Int, field: Int, strides: [Int]) -> Float {
        let offset = batch * strides[0] + row * strides[1] + field * strides[2]
        switch array.dataType {
        case .float32:
            return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .float16:
            let pointer = array.dataPointer.advanced(by: offset * MemoryLayout<Float16>.stride)
                .assumingMemoryBound(to: Float16.self)
            return Float(pointer.pointee)
        case .double:
            return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default:
            return array[[NSNumber(value: batch), NSNumber(value: row), NSNumber(value: field)]].floatValue
        }
    }
}
