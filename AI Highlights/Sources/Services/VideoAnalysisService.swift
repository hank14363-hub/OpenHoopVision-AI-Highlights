import AVFoundation
import CoreImage
import Foundation

typealias AnalysisProgressHandler = @MainActor @Sendable (
    _ fraction: Double, _ message: String, _ performance: AnalysisPerformance?
) -> Void
typealias AnalysisCheckpointHandler = @MainActor @Sendable (AnalysisCheckpointBatch) async -> Bool

actor VideoAnalysisService {
    private var cachedScan: CompletedScan?

    func analyze(videoURL: URL, confidenceThreshold: Double = AnalysisSettings.defaultThreshold, execution: AnalysisExecutionPolicy? = nil, reuseCachedScan: Bool = true, resumeHits: [AnalysisHit] = [], checkpoint: @escaping AnalysisCheckpointHandler = { _ in true }, progress: @escaping AnalysisProgressHandler) async throws -> VideoAnalysisResult {
        try await analyze(source: .appFile(videoURL), confidenceThreshold: confidenceThreshold,
                          execution: execution, reuseCachedScan: reuseCachedScan,
                          resumeHits: resumeHits, checkpoint: checkpoint, progress: progress)
    }

    func analyze(source: VideoSourceReference, confidenceThreshold: Double = AnalysisSettings.defaultThreshold, execution: AnalysisExecutionPolicy? = nil, reuseCachedScan: Bool = true, resumeHits: [AnalysisHit] = [], checkpoint: @escaping AnalysisCheckpointHandler = { _ in true }, progress: @escaping AnalysisProgressHandler) async throws -> VideoAnalysisResult {
        let threshold = AnalysisSettings.normalizedThreshold(confidenceThreshold)
        let identity = try VideoIdentity(source: source)
        if resumeHits.isEmpty, reuseCachedScan, let scan = cachedScan, scan.identity == identity {
            try Task.checkCancellation()
            let result = makeResult(scan: scan, threshold: threshold)
            let performance = AnalysisPerformance(
                processedFrames: scan.scores.count, elapsedSeconds: scan.performance.elapsedSeconds,
                videoFraction: 1, totalFrames: scan.scores.count, detectedGoals: result.candidates.count,
                processedVideoTime: scan.duration, totalVideoDuration: scan.duration
            )
            await progress(1, String(localized: "\(scan.scores.count) frames reused · Shot candidates: \(result.candidates.count)", bundle: AppLanguage.current.bundle), performance)
            return result
        }
        if resumeHits.isEmpty {
            await progress(0.02, String(localized: "Opening selected video", bundle: AppLanguage.current.bundle), nil)
        }
        let asset = try await source.avAsset()
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        guard duration.isFinite, duration > 0 else { throw VideoAnalysisError.unreadableVideo }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAnalysisError.unreadableVideo
        }
        let transform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let sourceFrameRate = nominalFrameRate.isFinite && nominalFrameRate > 0 ? Double(nominalFrameRate) : nil
        let metadata = VideoMetadata.from(naturalSize: naturalSize, preferredTransform: transform,
                                          frameRate: sourceFrameRate)
        var scores = resumeHits.filter {
            $0.time.isFinite && $0.confidence.isFinite && $0.time >= 0 && $0.time <= duration && (0...1).contains($0.confidence)
        }.sorted { $0.time == $1.time ? $0.confidence > $1.confidence : $0.time < $1.time }
        let resumeAfterTime = scores.last?.time
        if scores.isEmpty {
            await progress(0.03, String(localized: "Loading the basketball Core ML model", bundle: AppLanguage.current.bundle), nil)
        }
        var detector = execution?.isBackground == true ? nil : try CoreMLBasketballDetector(useGpu: true)
        let backgroundDetector: CoreMLBasketballDetector?
        if execution == nil { backgroundDetector = nil }
        // The current signing profile has no Background GPU or Background Inference entitlement.
        // Keep the fast all-units model for foreground use and pre-load a CPU-only model for background use.
        else { backgroundDetector = try CoreMLBasketballDetector(useGpu: false) }
        let readerStart = resumeAfterTime.map { CMTime(seconds: $0 + 0.001, preferredTimescale: 600) }
        let timeRange: CMTimeRange? = readerStart.flatMap { start in
            guard CMTimeCompare(start, assetDuration) < 0 else { return nil }
            return CMTimeRange(start: start, duration: CMTimeSubtract(assetDuration, start))
        }
        let hasReachedEnd = resumeAfterTime != nil && timeRange == nil
        let frames: VideoFrameReader?
        if hasReachedEnd {
            frames = nil
        } else {
            frames = try VideoFrameReader(asset: asset, track: track, transform: transform,
                sourceFrameRate: sourceFrameRate, execution: execution, timeRange: timeRange)
        }
        defer { frames?.cancel() }
        var processedFrames = scores.count
        var backgroundFrames = 0
        var highestConfidence = scores.map(\.confidence).max() ?? 0
        var eventFilter = ShotEventFilter(threshold: threshold, frameRate: sourceFrameRate)
        let scoreboardDetector = ScoreboardDetector()
        var scoreFilter = ScoreChangeFilter()
        var lastScoreboardTime = scores.last(where: { $0.scoreboardSampled == true })?.time ?? -.infinity
        for hit in scores {
            eventFilter.append(ShotEventFilter.Sample(time: hit.time, confidence: hit.confidence))
            if hit.scoreboardSampled == true { scoreFilter.append(time: hit.time, reading: hit.scoreboard) }
        }
        var detectedGoals = scoreFilter.candidates(visualEvents: eventFilter.currentEvents).count
        let processingStart = ProcessInfo.processInfo.systemUptime
        var lastProgressUpdate = processingStart
        var lastCheckpointTime = processingStart
        var fpsSamples: [(uptime: TimeInterval, frames: Int)] = [(processingStart, processedFrames)]
        var pendingCheckpointHits: [AnalysisHit] = []

        func recentFPS(at uptime: TimeInterval, processedFrames: Int) -> Double? {
            fpsSamples.append((uptime, processedFrames))
            let cutoff = uptime - 1
            while fpsSamples.count > 2, fpsSamples[1].uptime <= cutoff {
                fpsSamples.removeFirst()
            }
            guard let first = fpsSamples.first else { return nil }
            let interval = uptime - first.uptime
            guard interval >= 0.5 else { return nil }
            let rate = Double(processedFrames - first.frames) / interval
            return rate.isFinite && rate > 0 ? rate : nil
        }

        let initialVideoTime = resumeAfterTime ?? 0
        let initialVideoFraction = min(1, max(0, initialVideoTime / duration))
        await progress(0.04 + 0.92 * initialVideoFraction,
            String(localized: "Goals detected: \(detectedGoals)", bundle: AppLanguage.current.bundle),
            AnalysisPerformance(processedFrames: processedFrames, elapsedSeconds: 0,
                videoFraction: initialVideoFraction, detectedGoals: detectedGoals,
                processedVideoTime: initialVideoTime, totalVideoDuration: duration))

        func flushCheckpoint() async {
            guard !pendingCheckpointHits.isEmpty, let lastHit = pendingCheckpointHits.last else { return }
            detectedGoals = scoreFilter.candidates(visualEvents: eventFilter.currentEvents).count
            let processedVideoTime = min(duration, max(0, lastHit.time))
            let videoFraction = min(1, max(0, processedVideoTime / duration))
            let performance = AnalysisPerformance(processedFrames: processedFrames,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - processingStart,
                videoFraction: videoFraction, detectedGoals: detectedGoals,
                backgroundFrames: backgroundFrames, processedVideoTime: processedVideoTime,
                totalVideoDuration: duration)
            let saved = await checkpoint(AnalysisCheckpointBatch(hits: pendingCheckpointHits,
                progressFraction: 0.04 + 0.92 * videoFraction, performance: performance))
            if saved { pendingCheckpointHits.removeAll(keepingCapacity: true) }
            lastCheckpointTime = ProcessInfo.processInfo.systemUptime
        }

        do {
            while let frameReader = frames, let frame = try frameReader.next() {
                try Task.checkCancellation()
                let timestamp = frame.timestamp
                guard timestamp.isFinite else { throw VideoAnalysisError.unreadableVideo }
                if let resumeAfterTime, timestamp <= resumeAfterTime { continue }
                if detector == nil, execution?.isBackground != true {
                    detector = try CoreMLBasketballDetector(useGpu: true)
                }
                var usedBackground = false
                let confidence = try autoreleasepool {
                    func detect(background: Bool) throws -> Double {
                        if background, let backgroundDetector {
                            usedBackground = true
                            return try backgroundDetector.ballInBasketConfidence(in: frameReader.backgroundImage(for: frame))
                        }
                        guard let detector else { throw DetectorError.missingModel }
                        do { return try detector.ballInBasketConfidence(in: frame.image) }
                        catch {
                            guard let backgroundDetector else { throw error }
                            usedBackground = true
                            return try backgroundDetector.ballInBasketConfidence(in: frameReader.backgroundImage(for: frame))
                        }
                    }
                    if let execution { return try execution.withFrameAccess { try detect(background: $0) } }
                    return try detect(background: false)
                }
                processedFrames += 1
                if usedBackground { backgroundFrames += 1 }
                highestConfidence = max(highestConfidence, confidence)
                let scoreboardSampled = timestamp - lastScoreboardTime >= 0.5 - 0.001
                let scoreboard: ScoreboardReading?
                if scoreboardSampled {
                    // Software rendering keeps sparse OCR safe during a background transition.
                    scoreboard = try autoreleasepool {
                        let image = execution == nil ? frame.image : try frameReader.backgroundImage(for: frame)
                        return scoreboardDetector.reading(in: image)
                    }
                    lastScoreboardTime = timestamp
                    scoreFilter.append(time: timestamp, reading: scoreboard)
                } else { scoreboard = nil }
                let hit = AnalysisHit(time: timestamp, confidence: confidence,
                                      scoreboardSampled: scoreboardSampled ? true : nil, scoreboard: scoreboard)
                scores.append(hit)
                pendingCheckpointHits.append(hit)
                eventFilter.append(ShotEventFilter.Sample(time: timestamp, confidence: confidence))
                let now = ProcessInfo.processInfo.systemUptime
                let frameDuration = frame.duration
                let frameEnd = timestamp + (frameDuration.isFinite && frameDuration > 0 ? frameDuration : 0)
                let videoFraction = min(1, max(0, frameEnd / duration))
                if processedFrames == 1 || now - lastProgressUpdate >= 0.5 {
                    lastProgressUpdate = now
                    detectedGoals = scoreFilter.candidates(visualEvents: eventFilter.currentEvents).count
                    let performance = AnalysisPerformance(
                        processedFrames: processedFrames,
                        elapsedSeconds: now - processingStart,
                        videoFraction: videoFraction,
                        detectedGoals: detectedGoals,
                        backgroundFrames: backgroundFrames,
                        processedVideoTime: min(duration, max(0, frameEnd)), totalVideoDuration: duration,
                        recentFramesPerSecond: recentFPS(at: now, processedFrames: processedFrames)
                    )
                    await progress(
                        0.04 + 0.92 * videoFraction,
                        String(localized: "Goals detected: \(detectedGoals)", bundle: AppLanguage.current.bundle),
                        performance
                    )
                }
                if now - lastCheckpointTime >= 5 {
                    await flushCheckpoint()
                }
            }
        } catch {
            await flushCheckpoint()
            throw error
        }
        await flushCheckpoint()
        try Task.checkCancellation()
        guard processedFrames > 0 else { throw VideoAnalysisError.unreadableVideo }

        detectedGoals = scoreFilter.candidates(visualEvents: eventFilter.finish()).count
        let finishedAt = ProcessInfo.processInfo.systemUptime
        let rollingFPS = recentFPS(at: finishedAt, processedFrames: processedFrames)
        let performance = AnalysisPerformance(
            processedFrames: processedFrames,
            elapsedSeconds: finishedAt - processingStart,
            videoFraction: 1, totalFrames: processedFrames, detectedGoals: detectedGoals, backgroundFrames: backgroundFrames,
            processedVideoTime: duration, totalVideoDuration: duration, recentFramesPerSecond: rollingFPS
        )
        let scan = CompletedScan(identity: identity, duration: duration, frameRate: sourceFrameRate,
            scores: scores, highestConfidence: highestConfidence, performance: performance, metadata: metadata)
        cachedScan = scan
        let result = makeResult(scan: scan, threshold: threshold)
        await progress(1, String(localized: "\(processedFrames) frames analyzed · Shot candidates: \(result.candidates.count)", bundle: AppLanguage.current.bundle), performance)
        return result
    }

    private func makeResult(scan: CompletedScan, threshold: Double) -> VideoAnalysisResult {
        var scoreFilter = ScoreChangeFilter()
        for hit in scan.scores where hit.scoreboardSampled == true {
            scoreFilter.append(time: hit.time, reading: hit.scoreboard)
        }
        let visualEvents = ShotEventFilter.events(
            in: scan.scores.map { ShotEventFilter.Sample(time: $0.time, confidence: $0.confidence) },
            threshold: threshold, frameRate: scan.frameRate)
        return VideoAnalysisResult(
            duration: scan.duration,
            candidates: scoreFilter.candidates(visualEvents: visualEvents).map { event in
                ShotCandidate(eventTime: min(max(0, event.time), scan.duration), confidence: event.confidence,
                              origin: event.isScoreboard ? .scoreboard : nil)
            },
            processedFrames: scan.scores.count, highestConfidence: scan.highestConfidence,
            confidenceThreshold: threshold, metadata: scan.metadata
        )
    }

}

private struct VideoIdentity: Equatable {
    let sourceKey: String
    let size: Int?
    let modifiedAt: Date?

    init(source: VideoSourceReference) throws {
        switch source {
        case .appFile(let url):
            var freshURL = url.standardizedFileURL
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            sourceKey = source.cacheIdentity
            size = values.fileSize
            modifiedAt = values.contentModificationDate
        case .photoLibrary:
            sourceKey = source.cacheIdentity
            size = nil
            modifiedAt = nil
        }
    }
}

private struct CompletedScan {
    let identity: VideoIdentity
    let duration: TimeInterval
    let frameRate: Double?
    let scores: [AnalysisHit]
    let highestConfidence: Double
    let performance: AnalysisPerformance
    let metadata: VideoMetadata?
}
