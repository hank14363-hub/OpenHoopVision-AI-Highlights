import CoreGraphics
import Foundation
import Observation

struct AnalysisHit: Codable, Sendable {
    let time: TimeInterval
    let confidence: Double
    var scoreboardSampled: Bool? = nil
    var scoreboard: ScoreboardReading? = nil
    var objects: [BasketballObject]? = nil
}

struct AnalysisCheckpointBatch: Sendable {
    let hits: [AnalysisHit]
    let progressFraction: Double
    let performance: AnalysisPerformance
}

struct VideoAnalysisResult: Codable, Sendable {
    let duration: TimeInterval
    var candidates: [ShotCandidate]
    let processedFrames: Int
    let highestConfidence: Double
    let confidenceThreshold: Double
    var metadata: VideoMetadata? = nil
}

enum VideoAnalysisError: LocalizedError {
    case unreadableVideo

    var errorDescription: String? {
        switch self {
        case .unreadableVideo:
            return String(localized: "Unable to read this video. Try the original MOV or MP4 from your photo library.", bundle: AppLanguage.current.bundle)
        }
    }
}

struct AnalysisPerformance: Codable, Sendable {
    let processedFrames: Int
    let elapsedSeconds: TimeInterval
    let recentFramesPerSecond: Double?
    let videoFraction: Double
    let totalFrames: Int?
    let detectedGoals: Int
    let backgroundFrames: Int?
    let processedVideoTime: TimeInterval?
    let totalVideoDuration: TimeInterval?

    init(processedFrames: Int, elapsedSeconds: TimeInterval, videoFraction: Double, totalFrames: Int? = nil, detectedGoals: Int = 0, backgroundFrames: Int? = nil, processedVideoTime: TimeInterval? = nil, totalVideoDuration: TimeInterval? = nil, recentFramesPerSecond: Double? = nil) {
        self.processedFrames = processedFrames
        self.elapsedSeconds = elapsedSeconds
        self.recentFramesPerSecond = recentFramesPerSecond
        self.videoFraction = videoFraction
        self.totalFrames = totalFrames
        self.detectedGoals = detectedGoals
        self.backgroundFrames = backgroundFrames
        self.processedVideoTime = processedVideoTime
        self.totalVideoDuration = totalVideoDuration
    }

    var averageFramesPerSecond: Double? {
        guard processedFrames > 0, elapsedSeconds.isFinite, elapsedSeconds >= 0.5 else { return nil }
        let rate = Double(processedFrames) / elapsedSeconds
        return rate.isFinite && rate > 0 ? rate : nil
    }

    var framesPerSecond: Double? {
        if let recentFramesPerSecond, recentFramesPerSecond.isFinite, recentFramesPerSecond > 0 {
            return recentFramesPerSecond
        }
        return averageFramesPerSecond
    }

    func estimatedRemainingSeconds(after accumulatedElapsedSeconds: TimeInterval = 0) -> TimeInterval? {
        guard framesPerSecond != nil, videoFraction.isFinite, videoFraction > 0,
              elapsedSeconds.isFinite, elapsedSeconds >= 0,
              accumulatedElapsedSeconds.isFinite, accumulatedElapsedSeconds >= 0 else { return nil }
        let fraction = min(1, videoFraction)
        let remaining = (accumulatedElapsedSeconds + elapsedSeconds) * (1 - fraction) / fraction
        return remaining.isFinite ? max(0, remaining) : nil
    }
}

enum AnalysisSettings {
    static let thresholdKey = "analysis.confidenceThreshold"
    static let reviewThresholdKey = "review.uncertainConfidenceThreshold"
    static let defaultReviewThreshold = 0.30
    static let clipLeadInKey = "clips.leadInSeconds"
    static let clipLeadOutKey = "clips.leadOutSeconds"
    static let defaultThreshold = 0.55
    static let thresholdRange = 0.05...0.95

    static func normalizedThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return defaultThreshold }
        return min(thresholdRange.upperBound, max(thresholdRange.lowerBound, (value * 100).rounded() / 100))
    }
}

enum BasketballModel {
    static let version = "yolo26-basketball-last-1280x736-rect-int8-v2-strict-motion-v4"
    static let resourceName = "BasketballDetector"
    static let inputWidth = 1280
    static let inputHeight = 736
}

/// Persisted only so older analysis records remain decodable. New jobs always use this fixed model shape.
enum AnalysisInputSize: Int, Codable, Sendable {
    case fixed1280x736 = 1280

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        _ = try container.decode(Int.self) // Accept legacy 512/768/1280 records; the model is now fixed.
        self = .fixed1280x736
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.fixed1280x736.rawValue)
    }
}

/// Keep every frame at or below 30 FPS; above that, select the nearest frame to each 30 FPS sample.
enum AnalysisSampling {
    static func includes(frameIndex: Int, sourceFrameRate: Double?) -> Bool {
        guard frameIndex >= 0 else { return false }
        guard let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 30 else { return true }
        let sampleIndex = (Double(frameIndex) * 30 / sourceFrameRate).rounded()
        return Int((sampleIndex * sourceFrameRate / 30).rounded()) == frameIndex
    }
}

enum VideoAnalysisStatus: String, Codable, Sendable {
    case queued, running, ready, empty, failed, cancelled, interrupted
    var isActive: Bool { self == .queued || self == .running }
}

struct VideoAnalysisJob: Identifiable, Codable, Sendable {
    let id: String
    var status: VideoAnalysisStatus
    var inputSize: AnalysisInputSize
    let threshold: Double
    var fraction: Double = 0
    var message: String = String(localized: "Waiting for analysis", bundle: AppLanguage.current.bundle)
    var performance: AnalysisPerformance?
    var accumulatedElapsedSeconds: TimeInterval? = nil
    var result: VideoAnalysisResult?
    var errorMessage: String?
    var forceRescan: Bool?
    var manualCandidates: [ShotCandidate]?
    var checkpointFileName: String? = nil
    var modelVersion: String? = nil
    var photoAssetVersion: String? = nil

    var candidateCount: Int { (result?.candidates.count ?? 0) + (manualCandidates?.count ?? 0) }

    var reviewCandidates: [ShotCandidate] {
        ((result?.candidates ?? []) + (manualCandidates ?? [])).sorted { $0.eventTime < $1.eventTime }
    }
}

@MainActor
@Observable
final class AnalysisJobProgress {
    var snapshot = AnalysisJobProgressSnapshot()
}

struct AnalysisJobProgressSnapshot {
    var fraction = 0.0
    var message = String(localized: "Waiting for analysis", bundle: AppLanguage.current.bundle)
    var performance: AnalysisPerformance?
}

struct VideoMetadata: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let frameRate: Double?

    static func from(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        frameRate: Double?
    ) -> VideoMetadata? {
        let displayedSize = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized.size
        guard displayedSize.width.isFinite, displayedSize.height.isFinite,
              displayedSize.width > 0, displayedSize.height > 0,
              displayedSize.width < Double(Int32.max), displayedSize.height < Double(Int32.max) else {
            return nil
        }
        return VideoMetadata(width: Int(displayedSize.width.rounded()), height: Int(displayedSize.height.rounded()),
                             frameRate: frameRate)
    }

    var label: String {
        var parts: [String] = []
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            parts.append("\(frameRate.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))) FPS")
        }
        return parts.joined(separator: " · ")
    }
}

struct LibraryVideo: Identifiable, Codable, Equatable, Sendable {
    var id: String { fileName }
    let fileName: String
    let displayName: String
    var duration: TimeInterval?
    let importedAt: Date
    var metadata: VideoMetadata?
    /// Set for Photos imports. The original stays in the system photo library.
    var photoAssetIdentifier: String? = nil
    var photoAssetModificationDate: Date? = nil
}

struct ImportedVideo: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceKey: String
    let displayName: String
    let source: VideoSourceReference
    let duration: TimeInterval

    init(id: UUID = UUID(), sourceKey: String, displayName: String, source: VideoSourceReference, duration: TimeInterval) {
        self.id = id
        self.sourceKey = sourceKey
        self.displayName = displayName
        self.source = source
        self.duration = duration
    }
}

enum VideoSourceReference: Equatable, Sendable {
    case appFile(URL)
    case photoLibrary(localIdentifier: String)

    var cacheIdentity: String {
        switch self {
        case .appFile(let url): return "file:\(url.standardizedFileURL.path)"
        case .photoLibrary(let localIdentifier): return "photo-current:\(localIdentifier)"
        }
    }

    var photoAssetIdentifier: String? {
        guard case .photoLibrary(let localIdentifier) = self else { return nil }
        return localIdentifier
    }
}

struct ShotCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let eventTime: TimeInterval
    let confidence: Double
    var isSelected: Bool
    var origin: Origin?
    /// Nil for legacy records, true once the user explicitly changes selection.
    var hasManualSelectionOverride: Bool?

    enum Origin: String, Codable, Sendable { case manual, scoreboard, visualReview }
    var isManual: Bool { origin == .manual }
    var isScoreboard: Bool { origin == .scoreboard }
    var needsVisualReview: Bool { origin == .visualReview }

    init(id: UUID = UUID(), eventTime: TimeInterval, confidence: Double, isSelected: Bool = true, origin: Origin? = nil, hasManualSelectionOverride: Bool? = nil) {
        self.id = id
        self.eventTime = eventTime
        self.confidence = confidence
        self.isSelected = isSelected
        self.origin = origin
        self.hasManualSelectionOverride = hasManualSelectionOverride
    }

    func clipRange(videoDuration: TimeInterval, settings: HighlightClipSettings = .default) -> ClipRange {
        // Score graphics update after the play. Include enough context for
        // review instead of cutting at the late graphic update itself.
        let before = isScoreboard ? max(8, settings.before) : settings.before
        let after = isScoreboard ? max(3, settings.after) : settings.after
        let start = min(videoDuration, max(0, eventTime - before))
        let end = min(videoDuration, eventTime + after)
        return ClipRange(start: start, end: max(start, end))
    }
}

struct HighlightClipSettings: Codable, Hashable, Sendable {
    static let `default` = HighlightClipSettings(before: 4, after: 1)
    let before: TimeInterval
    let after: TimeInterval

    init(before: TimeInterval, after: TimeInterval) {
        self.before = Self.normalized(before, fallback: 4)
        self.after = Self.normalized(after, fallback: 1)
    }

    private static func normalized(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(30, max(0, (value * 10).rounded() / 10))
    }
}

struct ClipRange: Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { max(0, end - start) }

    static func merged(_ ranges: [ClipRange]) -> [ClipRange] {
        let ordered = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.duration > 0 }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [ClipRange] = []
        for range in ordered {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = ClipRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }
}

struct HighlightProject: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var sourceFileName: String
    var sourcePhotoAssetIdentifier: String?
    var sourceDisplayName: String
    var duration: TimeInterval
    var candidates: [ShotCandidate]
    var clipSettings: HighlightClipSettings?
    var outputFileName: String?
    var outputDuration: TimeInterval?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        sourceFileName: String,
        sourcePhotoAssetIdentifier: String? = nil,
        sourceDisplayName: String,
        duration: TimeInterval,
        candidates: [ShotCandidate],
        clipSettings: HighlightClipSettings = .default,
        outputFileName: String? = nil,
        outputDuration: TimeInterval? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sourceFileName = sourceFileName
        self.sourcePhotoAssetIdentifier = sourcePhotoAssetIdentifier
        self.sourceDisplayName = sourceDisplayName
        self.duration = duration
        self.candidates = candidates
        self.clipSettings = clipSettings
        self.outputFileName = outputFileName
        self.outputDuration = outputDuration
        self.createdAt = createdAt
    }

    var selectedCandidateCount: Int { candidates.lazy.filter(\.isSelected).count }

    var selectedCandidates: [ShotCandidate] {
        candidates.filter(\.isSelected).sorted { $0.eventTime < $1.eventTime }
    }

    func clipRange(for candidate: ShotCandidate) -> ClipRange {
        candidate.clipRange(videoDuration: duration, settings: clipSettings ?? .default)
    }

    var mergedClipRanges: [ClipRange] {
        // The union already sorts ranges; no need to sort selected candidates first.
        ClipRange.merged(candidates.filter(\.isSelected).map { clipRange(for: $0) })
    }

    var selectedDuration: TimeInterval {
        mergedClipRanges.reduce(0) { $0 + $1.duration }
    }

    var generatedDuration: TimeInterval { outputDuration ?? selectedDuration }
}

extension TimeInterval {
    var highlightTimestamp: String {
        let totalTenths = max(0, Int((self * 10).rounded()))
        let minutes = totalTenths / 600
        let seconds = (totalTenths % 600) / 10
        let tenths = totalTenths % 10
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    var highlightDuration: String {
        let seconds = max(0, Int(rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
