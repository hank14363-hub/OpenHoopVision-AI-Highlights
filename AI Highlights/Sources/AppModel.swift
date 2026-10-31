import AVFoundation
import Foundation
import Observation

enum AppAnalysisOutcome {
    case candidates(HighlightProject)
    case noCandidates(VideoAnalysisResult)
}

@MainActor
@Observable
final class AppModel {
    private(set) var projects: [HighlightProject]
    private(set) var draft: HighlightProject?
    private(set) var videos: [LibraryVideo]
    private(set) var confidenceThreshold: Double
    private(set) var uncertainConfidenceThreshold: Double
    private(set) var clipSettings: HighlightClipSettings
    private(set) var analysisJobs: [String: VideoAnalysisJob] {
        didSet {
            let active = analysisJobs.values.contains { $0.status.isActive }
            if hasActiveAnalyses != active { hasActiveAnalyses = active }
        }
    }
    private(set) var analysisProgress: [String: AnalysisJobProgress] = [:]
    // Views that only need active/idle state do not observe individual progress updates.
    private(set) var hasActiveAnalyses = false
    var activeVideo: ImportedVideo?
    var progress = 0.0
    var progressMessage = String(localized: "Ready to start", bundle: AppLanguage.current.bundle)
    var analysisPerformance: AnalysisPerformance?
    var isExporting = false
    private(set) var analysisPersistenceErrorMessage: String?
    private(set) var repositoryLoadErrorMessage: String?

    @ObservationIgnored private let repository: ProjectRepository
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let analysisService = VideoAnalysisService()
    @ObservationIgnored private let compositionService = VideoCompositionService()
    @ObservationIgnored private var pendingAnalyses: [String] = []
    @ObservationIgnored private var restartAfterCancellation: Set<String> = []
    @ObservationIgnored private var analysisRunner: Task<Void, Never>?
    @ObservationIgnored private var currentAnalysis: Task<VideoAnalysisResult, Error>?
    @ObservationIgnored private var runningVideoID: String?
    @ObservationIgnored private var completedInBatch = 0
    @ObservationIgnored private var hasBackgroundSession = false
    @ObservationIgnored private var backgroundBatchVideoIDs: Set<String> = []

    init(repository: ProjectRepository = ProjectRepository(), preferences: UserDefaults = .standard) {
        self.repository = repository
        self.preferences = preferences
        self.confidenceThreshold = AnalysisSettings.normalizedThreshold(
            (preferences.object(forKey: AnalysisSettings.thresholdKey) as? NSNumber)?.doubleValue ?? AnalysisSettings.defaultThreshold
        )
        self.uncertainConfidenceThreshold = AnalysisSettings.normalizedThreshold(
            (preferences.object(forKey: AnalysisSettings.reviewThresholdKey) as? NSNumber)?.doubleValue ?? AnalysisSettings.defaultReviewThreshold
        )
        self.clipSettings = HighlightClipSettings(
            before: (preferences.object(forKey: AnalysisSettings.clipLeadInKey) as? NSNumber)?.doubleValue ?? 4,
            after: (preferences.object(forKey: AnalysisSettings.clipLeadOutKey) as? NSNumber)?.doubleValue ?? 1
        )
        let projectsLoad = repository.loadProjects()
        self.projects = projectsLoad.value
        let videosLoad = repository.loadVideos()
        let storedVideos = videosLoad.value
        self.videos = storedVideos
        let analysesLoad = repository.loadAnalyses()
        var loadedJobs = analysesLoad.value
        var didMigratePhotoJobs = false
        var invalidatedCheckpointFiles: [String] = []
        for video in storedVideos where video.photoAssetIdentifier != nil {
            guard var job = loadedJobs[video.id],
                  job.photoAssetVersion != PhotoLibraryVideoService.currentVersionIdentifier else { continue }
            if let checkpointFileName = job.checkpointFileName {
                invalidatedCheckpointFiles.append(checkpointFileName)
            }
            job.result = nil
            job.performance = nil
            job.fraction = 0
            job.forceRescan = true
            job.checkpointFileName = nil
            job.photoAssetVersion = PhotoLibraryVideoService.currentVersionIdentifier
            job.errorMessage = nil
            job.status = .interrupted
            job.message = String(localized: "The Photos video changed. Run analysis again.", bundle: AppLanguage.current.bundle)
            loadedJobs[video.id] = job
            didMigratePhotoJobs = true
        }
        self.analysisJobs = loadedJobs
        let loadErrors = [projectsLoad.errorMessage, videosLoad.errorMessage, analysesLoad.errorMessage].compactMap { $0 }
        self.repositoryLoadErrorMessage = loadErrors.isEmpty ? nil : loadErrors.joined(separator: "\n")
        if didMigratePhotoJobs {
            do {
                try repository.saveAnalyses(loadedJobs)
                invalidatedCheckpointFiles.forEach { repository.removeAnalysisCheckpoint(fileName: $0) }
            } catch {
                self.analysisPersistenceErrorMessage = error.localizedDescription
            }
        }
    }

    var mostRecentProject: HighlightProject? { projects.sorted { $0.createdAt > $1.createdAt }.first }

    func startAnalysis(for video: LibraryVideo, forceRescan: Bool = false, threshold: Double? = nil) {
        guard analysisJobs[video.id]?.status.isActive != true else { return }
        let previousJob = analysisJobs[video.id]
        let previousCheckpoint = previousJob?.checkpointFileName
        let canResume = !forceRescan && previousCheckpoint != nil
        let newCheckpointFileName = "\(UUID().uuidString).jsonl"
        let checkpointFileName = canResume ? (previousCheckpoint ?? newCheckpointFileName) : newCheckpointFileName
        let effectiveThreshold = threshold ?? (canResume ? previousJob?.threshold : nil) ?? confidenceThreshold
        var job = VideoAnalysisJob(
            id: video.id, status: .queued, inputSize: .fixed1280x736,
            threshold: AnalysisSettings.normalizedThreshold(effectiveThreshold)
        )
        job.modelVersion = BasketballModel.version
        job.photoAssetVersion = video.photoAssetIdentifier == nil ? nil : PhotoLibraryVideoService.currentVersionIdentifier
        job.forceRescan = forceRescan || previousJob?.forceRescan == true
        job.manualCandidates = previousJob?.manualCandidates
        job.checkpointFileName = checkpointFileName
        job.accumulatedElapsedSeconds = canResume
            ? previousJob?.accumulatedElapsedSeconds ?? previousJob?.performance?.elapsedSeconds ?? 0
            : 0
        if previousCheckpoint == checkpointFileName {
            job.fraction = previousJob?.fraction ?? 0
            job.message = String(localized: "Continuing analysis", bundle: AppLanguage.current.bundle)
        }
        analysisJobs[video.id] = job
        let progress = AnalysisJobProgress()
        if previousCheckpoint == checkpointFileName {
            progress.snapshot = AnalysisJobProgressSnapshot(fraction: job.fraction, message: job.message)
        }
        analysisProgress[video.id] = progress
        pendingAnalyses.append(video.id)
        if hasBackgroundSession { backgroundBatchVideoIDs.insert(video.id) }
        guard persistAnalyses() else {
            pendingAnalyses.removeAll { $0 == video.id }
            analysisProgress.removeValue(forKey: video.id)
            analysisJobs[video.id] = previousJob
            return
        }
        if previousCheckpoint != checkpointFileName {
            repository.removeAnalysisCheckpoint(fileName: previousCheckpoint)
        }
        ensureBackgroundSession()
    }

    func restartAnalysis(videoID: String) {
        guard !isExporting, let video = videos.first(where: { $0.id == videoID }) else { return }
        if analysisJobs[videoID]?.status.isActive == true {
            if runningVideoID == videoID {
                restartAfterCancellation.insert(videoID)
                cancelAnalysis(videoID: videoID)
                return
            }
            cancelAnalysis(videoID: videoID)
        }
        let previousCheckpoint = analysisJobs[videoID]?.checkpointFileName
        let threshold = analysisJobs[videoID]?.threshold ?? confidenceThreshold
        if draft?.sourceFileName == video.fileName { discardDraft() }
        startAnalysis(for: video, forceRescan: true, threshold: threshold)
        if analysisJobs[videoID]?.checkpointFileName != previousCheckpoint {
            repository.removeAnalysisCheckpoint(fileName: previousCheckpoint)
        }
    }

    func continueAnalysis(videoID: String) {
        guard !isExporting, analysisJobs[videoID]?.status.isActive != true,
              let video = videos.first(where: { $0.id == videoID }) else { return }
        let threshold = analysisJobs[videoID]?.threshold ?? confidenceThreshold
        if draft?.sourceFileName == video.fileName { discardDraft() }
        startAnalysis(for: video, threshold: threshold)
    }

    func canContinueAnalysis(videoID: String) -> Bool {
        guard let job = analysisJobs[videoID], !job.status.isActive else { return false }
        return job.checkpointFileName != nil
    }

    private func ensureBackgroundSession() {
        guard !hasBackgroundSession, analysisRunner == nil, !pendingAnalyses.isEmpty else { return }
        hasBackgroundSession = true
        completedInBatch = 0
        backgroundBatchVideoIDs = Set(pendingAnalyses)
        do {
            try AnalysisBackgroundController.shared.begin(onStart: { [weak self] in self?.runAnalysisQueue() }, onExpiration: { [weak self] in
                self?.interruptAnalyses()
            })
        } catch {
            hasBackgroundSession = false
            backgroundBatchVideoIDs.removeAll()
            for id in pendingAnalyses {
                commitProgress(for: id)
                if var job = analysisJobs[id] {
                    job.status = .failed
                    job.errorMessage = error.localizedDescription
                    analysisJobs[id] = job
                }
            }
            pendingAnalyses.removeAll()
            persistAnalyses()
        }
    }

    func cancelAnalysis(videoID: String) {
        guard analysisJobs[videoID]?.status.isActive == true else { return }
        pendingAnalyses.removeAll { $0 == videoID }
        commitProgress(for: videoID, preserveCheckpoint: true)
        if var job = analysisJobs[videoID] {
            job.status = .cancelled
            job.message = String(localized: "Analysis paused", bundle: AppLanguage.current.bundle)
            analysisJobs[videoID] = job
        }
        if runningVideoID == videoID { currentAnalysis?.cancel() }
        persistAnalyses()
        if pendingAnalyses.isEmpty, runningVideoID == nil {
            hasBackgroundSession = false
            backgroundBatchVideoIDs.removeAll()
            AnalysisBackgroundController.shared.finish(success: false)
        }
    }

    func reviewAnalysis(videoID: String) -> HighlightProject? {
        guard let video = videos.first(where: { $0.id == videoID }),
              var job = analysisJobs[videoID], let storedResult = job.result, !job.status.isActive else { return nil }
        let result = applyingDefaultClipSelection(to: storedResult)
        if result.candidates != storedResult.candidates {
            job.result = result
            analysisJobs[videoID] = job
            persistAnalyses()
        }
        let project = HighlightProject(title: URL(fileURLWithPath: video.displayName).deletingPathExtension().lastPathComponent,
            sourceFileName: video.fileName, sourcePhotoAssetIdentifier: video.photoAssetIdentifier,
            sourceDisplayName: video.displayName, duration: result.duration, candidates: job.reviewCandidates, clipSettings: clipSettings)
        draft = project
        return project
    }

    private func runAnalysisQueue() {
        guard analysisRunner == nil else { return }
        analysisRunner = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let execution = AnalysisExecutionPolicy()
            while hasBackgroundSession && !pendingAnalyses.isEmpty {
                let id = pendingAnalyses.removeFirst()
                backgroundBatchVideoIDs.insert(id)
                guard let video = videos.first(where: { $0.id == id }), let job = analysisJobs[id], job.status == .queued else { continue }
                runningVideoID = id
                if var runningJob = analysisJobs[id] {
                    runningJob.status = .running
                    runningJob.message = String(localized: "Loading model", bundle: AppLanguage.current.bundle)
                    analysisJobs[id] = runningJob
                }
                analysisProgress[id]?.snapshot.message = String(localized: "Loading model", bundle: AppLanguage.current.bundle)
                persistAnalyses()
                let source = videoSource(for: video)
                let checkpointFileName = job.checkpointFileName
                var resumeHits: [AnalysisHit] = []
                if let checkpointFileName {
                    let checkpointRepository = repository
                    do {
                        resumeHits = try await Task.detached(priority: .utility) {
                            try checkpointRepository.loadAnalysisCheckpoint(fileName: checkpointFileName)
                        }.value
                    } catch {
                        analysisPersistenceErrorMessage = error.localizedDescription
                    }
                }
                guard analysisJobs[id]?.status == .running else {
                    runningVideoID = nil
                    if restartAfterCancellation.remove(id) != nil {
                        restartAnalysis(videoID: id)
                    }
                    continue
                }
                currentAnalysis = Task(priority: .userInitiated) { [self] in
                    try await self.analysisService.analyze(source: source, confidenceThreshold: job.threshold,
                        execution: execution, reuseCachedScan: job.forceRescan != true && resumeHits.isEmpty,
                        resumeHits: resumeHits,
                        checkpoint: { [weak self] batch in
                            guard let self, let checkpointFileName,
                                  var checkpointJob = self.analysisJobs[id],
                                  checkpointJob.checkpointFileName == checkpointFileName else { return false }
                            do {
                                try self.repository.appendAnalysisCheckpoint(batch.hits, fileName: checkpointFileName)
                                checkpointJob.fraction = batch.progressFraction
                                checkpointJob.performance = batch.performance
                                checkpointJob.message = String(localized: "Goals detected: \(batch.performance.detectedGoals)", bundle: AppLanguage.current.bundle)
                                self.analysisJobs[id] = checkpointJob
                                self.persistAnalyses()
                                return true
                            } catch {
                                self.analysisPersistenceErrorMessage = error.localizedDescription
                                return false
                            }
                        },
                        progress: { [weak self] fraction, message, performance in
                            guard let self, self.analysisJobs[id]?.status == .running,
                                  let progress = self.analysisProgress[id] else { return }
                            progress.snapshot = AnalysisJobProgressSnapshot(
                                fraction: fraction, message: message, performance: performance
                            )
                            AnalysisBackgroundController.shared.update(completedJobs: self.completedInBatch,
                                remainingJobs: self.pendingAnalyses.count + 1, fraction: fraction, message: message)
                        })
                }
                var completedCheckpointFileName: String?
                do {
                    let result = applyingDefaultClipSelection(to: try await currentAnalysis!.value)
                    updateVideoMetadata(sourceKey: id, metadata: result.metadata)
                    commitProgress(for: id)
                    if var completedJob = analysisJobs[id], completedJob.status == .running {
                        completedCheckpointFileName = completedJob.checkpointFileName
                        completedJob.result = result
                        completedJob.fraction = 1
                        completedJob.forceRescan = false
                        completedJob.checkpointFileName = nil
                        let count = completedJob.candidateCount
                        completedJob.status = count == 0 ? .empty : .ready
                        completedJob.message = count == 0 ? String(localized: "Analysis complete. No highlights found.", bundle: AppLanguage.current.bundle) : String(localized: "Highlights found: \(count)", bundle: AppLanguage.current.bundle)
                        analysisJobs[id] = completedJob
                    }
                } catch is CancellationError {
                    // A cancelled item must never make the OS report this batch as completed.
                    if analysisJobs[id]?.status == .running {
                        commitProgress(for: id, preserveCheckpoint: true)
                        if var job = analysisJobs[id] {
                            job.status = .cancelled
                            analysisJobs[id] = job
                        }
                    }
                } catch {
                    if analysisJobs[id]?.status == .running {
                        commitProgress(for: id, preserveCheckpoint: true)
                        if var job = analysisJobs[id] {
                            job.status = .failed
                            job.errorMessage = error.localizedDescription
                            analysisJobs[id] = job
                        }
                    }
                }
                currentAnalysis = nil
                runningVideoID = nil
                if restartAfterCancellation.remove(id) != nil {
                    restartAnalysis(videoID: id)
                }
                completedInBatch += 1
                if persistAnalyses() {
                    repository.removeAnalysisCheckpoint(fileName: completedCheckpointFileName)
                }
            }
            analysisRunner = nil
            let shouldFinishBackgroundTask = hasBackgroundSession
            let batchCompletedSuccessfully = !backgroundBatchVideoIDs.isEmpty && backgroundBatchVideoIDs.allSatisfy { id in
                guard let status = self.analysisJobs[id]?.status else { return false }
                return status == .ready || status == .empty
            }
            hasBackgroundSession = false
            backgroundBatchVideoIDs.removeAll()
            if shouldFinishBackgroundTask {
                AnalysisBackgroundController.shared.finish(success: batchCompletedSuccessfully)
            }
            ensureBackgroundSession()
        }
    }

    private func interruptAnalyses() {
        currentAnalysis?.cancel()
        for id in pendingAnalyses + [runningVideoID].compactMap({ $0 }) where analysisJobs[id]?.status.isActive == true {
            commitProgress(for: id, preserveCheckpoint: true)
            if var job = analysisJobs[id] {
                job.status = .interrupted
                job.message = String(localized: "Analysis interrupted. You can start again.", bundle: AppLanguage.current.bundle)
                analysisJobs[id] = job
            }
        }
        pendingAnalyses.removeAll()
        hasBackgroundSession = false
        backgroundBatchVideoIDs.removeAll()
        persistAnalyses()
    }

    @discardableResult
    private func persistAnalyses() -> Bool {
        do {
            try repository.saveAnalyses(analysisJobs)
            analysisPersistenceErrorMessage = nil
            return true
        } catch {
            if analysisPersistenceErrorMessage == nil {
                analysisPersistenceErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func commitProgress(for videoID: String, preserveCheckpoint: Bool = false) {
        guard let progress = analysisProgress.removeValue(forKey: videoID),
              var job = analysisJobs[videoID] else { return }
        if !preserveCheckpoint || job.checkpointFileName == nil {
            job.fraction = progress.snapshot.fraction
            job.message = progress.snapshot.message
            job.performance = progress.snapshot.performance
        }
        if let elapsedSeconds = progress.snapshot.performance?.elapsedSeconds,
           elapsedSeconds.isFinite, elapsedSeconds > 0 {
            job.accumulatedElapsedSeconds = (job.accumulatedElapsedSeconds ?? 0) + elapsedSeconds
        }
        analysisJobs[videoID] = job
    }

    func dismissAnalysisPersistenceError() {
        analysisPersistenceErrorMessage = nil
    }

    func dismissRepositoryLoadError() {
        repositoryLoadErrorMessage = nil
    }

    func setConfidenceThreshold(_ value: Double) {
        confidenceThreshold = AnalysisSettings.normalizedThreshold(value)
        preferences.set(confidenceThreshold, forKey: AnalysisSettings.thresholdKey)
    }

    func setUncertainConfidenceThreshold(_ value: Double) {
        uncertainConfidenceThreshold = AnalysisSettings.normalizedThreshold(value)
        preferences.set(uncertainConfidenceThreshold, forKey: AnalysisSettings.reviewThresholdKey)
    }

    func setClipSettings(before: TimeInterval, after: TimeInterval) {
        clipSettings = HighlightClipSettings(before: before, after: after)
        preferences.set(clipSettings.before, forKey: AnalysisSettings.clipLeadInKey)
        preferences.set(clipSettings.after, forKey: AnalysisSettings.clipLeadOutKey)
    }

    func importVideo(from sourceURL: URL) async throws {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let repository = self.repository
        let imported = try await Task.detached(priority: .userInitiated) {
            try repository.importVideo(from: sourceURL)
        }.value
        do {
            let duration = try await AVURLAsset(url: imported.fileURL).load(.duration).seconds
            try Task.checkCancellation()
            guard duration.isFinite, duration > 0 else { throw VideoAnalysisError.unreadableVideo }
            let record = LibraryVideo(
                fileName: imported.fileURL.lastPathComponent, displayName: imported.displayName,
                duration: duration, importedAt: .now,
                metadata: try? await Self.readVideoMetadata(from: imported.fileURL)
            )
            try Task.checkCancellation()
            let updatedVideos = [record] + videos
            try repository.saveVideos(updatedVideos)
            videos = updatedVideos
            activeVideo = ImportedVideo(
                sourceKey: imported.fileURL.lastPathComponent,
                displayName: imported.displayName,
                source: .appFile(imported.fileURL),
                duration: duration
            )
            draft = nil
            progress = 0
            progressMessage = String(localized: "Preparing analysis", bundle: AppLanguage.current.bundle)
            analysisPerformance = nil
        } catch {
            try? FileManager.default.removeItem(at: imported.fileURL)
            throw error
        }
    }

    /// Registers a Photos asset by identifier. This path never loads a file representation
    /// or copies the original movie into temporary or app storage.
    func importPhotoVideo(localIdentifier: String) async throws {
        let source = VideoSourceReference.photoLibrary(localIdentifier: localIdentifier)
        let snapshot = try await PhotoLibraryVideoService.snapshot(localIdentifier: localIdentifier)
        try Task.checkCancellation()
        if let index = videos.firstIndex(where: { $0.photoAssetIdentifier == localIdentifier }) {
            let existing = videos[index]
            let metadata = snapshot.width > 0 && snapshot.height > 0
                ? VideoMetadata(width: snapshot.width, height: snapshot.height, frameRate: nil)
                : nil
            let durationChanged: Bool
            if let oldDuration = existing.duration {
                durationChanged = abs(oldDuration - snapshot.duration) > 0.01
            } else {
                durationChanged = true
            }
            let sourceChanged = durationChanged || existing.photoAssetModificationDate != snapshot.modificationDate
            var updatedVideo = existing
            updatedVideo.duration = snapshot.duration
            updatedVideo.metadata = metadata
            updatedVideo.photoAssetModificationDate = snapshot.modificationDate
            if updatedVideo != existing {
                var updatedVideos = videos
                updatedVideos[index] = updatedVideo
                try repository.saveVideos(updatedVideos)
                videos = updatedVideos
            }
            if sourceChanged { invalidatePhotoAnalysis(for: existing.id) }
            activeVideo = ImportedVideo(sourceKey: existing.fileName, displayName: existing.displayName, source: source, duration: snapshot.duration)
            draft = nil
            progress = 0
            progressMessage = String(localized: "Preparing analysis", bundle: AppLanguage.current.bundle)
            analysisPerformance = nil
            return
        }

        let fileExtension = URL(fileURLWithPath: snapshot.displayName).pathExtension
        let suffix = fileExtension.isEmpty ? "mov" : fileExtension.lowercased()
        let sourceKey = "photo-\(UUID().uuidString).\(suffix)"
        let metadata = snapshot.width > 0 && snapshot.height > 0
            ? VideoMetadata(width: snapshot.width, height: snapshot.height, frameRate: nil)
            : nil
        let record = LibraryVideo(
            fileName: sourceKey,
            displayName: snapshot.displayName,
            duration: snapshot.duration,
            importedAt: .now,
            metadata: metadata,
            photoAssetIdentifier: localIdentifier,
            photoAssetModificationDate: snapshot.modificationDate
        )
        let updatedVideos = [record] + videos
        try repository.saveVideos(updatedVideos)
        videos = updatedVideos
        activeVideo = ImportedVideo(sourceKey: sourceKey, displayName: snapshot.displayName, source: source, duration: snapshot.duration)
        draft = nil
        progress = 0
        progressMessage = String(localized: "Preparing analysis", bundle: AppLanguage.current.bundle)
        analysisPerformance = nil
    }

    private func invalidatePhotoAnalysis(for videoID: String) {
        if analysisJobs[videoID]?.status.isActive == true {
            cancelAnalysis(videoID: videoID)
        }
        guard var job = analysisJobs[videoID] else { return }
        let checkpointFileName = job.checkpointFileName
        job.result = nil
        job.performance = nil
        job.fraction = 0
        job.forceRescan = true
        job.checkpointFileName = nil
        job.photoAssetVersion = PhotoLibraryVideoService.currentVersionIdentifier
        job.errorMessage = nil
        job.status = .interrupted
        job.message = String(localized: "The Photos video changed. Run analysis again.", bundle: AppLanguage.current.bundle)
        var updatedJobs = analysisJobs
        updatedJobs[videoID] = job
        analysisJobs = updatedJobs
        if persistAnalyses() { repository.removeAnalysisCheckpoint(fileName: checkpointFileName) }
        if draft?.sourceFileName == videoID { draft = nil }
    }

    /// Backfill legacy library entries once; never reread tracks during progress updates.
    /// Defer this optional work while inference is active.
    func loadMissingVideoMetadata() async {
        let pending = videos.filter { $0.metadata == nil }.map(\.id)
        for id in pending {
            guard !Task.isCancelled, !analysisJobs.values.contains(where: { $0.status.isActive }) else { return }
            guard let video = videos.first(where: { $0.id == id }), video.metadata == nil,
                  video.photoAssetIdentifier == nil else { continue }
            guard let metadata = try? await Self.readVideoMetadata(from: repository.videoURL(for: video)),
                  !Task.isCancelled, let index = videos.firstIndex(where: { $0.id == id }) else { continue }
            var updated = videos
            updated[index].metadata = metadata
            do {
                try repository.saveVideos(updated)
                videos = updated
            } catch let error as RepositoryError {
                repositoryLoadErrorMessage = error.localizedDescription
            } catch { /* Keep the old record usable; a later visit can retry. */ }
        }
    }

    private nonisolated static func readVideoMetadata(from url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAnalysisError.unreadableVideo
        }
        async let size = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        async let rate = track.load(.nominalFrameRate)
        let (naturalSize, preferredTransform, nominalFrameRate) = try await (size, transform, rate)
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0 ? Double(nominalFrameRate) : nil
        guard let metadata = VideoMetadata.from(naturalSize: naturalSize, preferredTransform: preferredTransform,
                                                frameRate: frameRate) else {
            throw VideoAnalysisError.unreadableVideo
        }
        return metadata
    }

    func prepareVideo(_ video: LibraryVideo) async throws {
        let source = videoSource(for: video)
        let duration: TimeInterval
        if let storedDuration = video.duration {
            duration = storedDuration
        } else {
            let asset = try await source.avAsset()
            duration = try await asset.load(.duration).seconds
        }
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0 else { throw VideoAnalysisError.unreadableVideo }
        activeVideo = ImportedVideo(sourceKey: video.fileName, displayName: video.displayName, source: source, duration: duration)
        draft = nil
        progress = 0
        progressMessage = String(localized: "Preparing analysis", bundle: AppLanguage.current.bundle)
        analysisPerformance = nil
    }

    func analyze(video: ImportedVideo) async throws -> AppAnalysisOutcome {
        draft = nil
        progress = 0.02
        progressMessage = String(localized: "Loading the basketball Core ML model", bundle: AppLanguage.current.bundle)
        analysisPerformance = nil
        let analyzedResult = try await analysisService.analyze(source: video.source,
            confidenceThreshold: confidenceThreshold) { [weak self] fraction, message, performance in
            guard let self, !Task.isCancelled else { return }
            self.progress = fraction
            self.progressMessage = message
            self.analysisPerformance = performance
        }
        let result = applyingDefaultClipSelection(to: analyzedResult)
        try Task.checkCancellation()
        updateVideoMetadata(sourceKey: video.sourceKey, metadata: result.metadata)
        guard !result.candidates.isEmpty else { return .noCandidates(result) }
        let project = HighlightProject(
            title: URL(fileURLWithPath: video.displayName).deletingPathExtension().lastPathComponent,
            sourceFileName: video.sourceKey,
            sourcePhotoAssetIdentifier: video.source.photoAssetIdentifier,
            sourceDisplayName: video.displayName,
            duration: result.duration,
            candidates: result.candidates,
            clipSettings: clipSettings
        )
        draft = project
        progress = 1
        return .candidates(project)
    }

    private func applyingDefaultClipSelection(to result: VideoAnalysisResult) -> VideoAnalysisResult {
        var result = result
        for index in result.candidates.indices
            where !result.candidates[index].isManual && result.candidates[index].hasManualSelectionOverride != true {
            result.candidates[index].isSelected = !result.candidates[index].needsVisualReview &&
                (result.candidates[index].isScoreboard || result.candidates[index].confidence >= uncertainConfidenceThreshold)
        }
        return result
    }

    func analysisDiagnosticData(projectID: UUID) throws -> Data {
        guard let project = project(withID: projectID) else { throw CompositionError.missingDraft }
        struct Report: Encodable {
            let schemaVersion: Int
            let appVersion: String
            let analysisVersion: String?
            let videoDuration: TimeInterval
            let result: VideoAnalysisResult?
            let reviewCandidates: [ShotCandidate]
        }
        let job = analysisJobs[project.sourceFileName]
        let report = Report(schemaVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            analysisVersion: job?.modelVersion, videoDuration: project.duration,
            result: job?.result, reviewCandidates: project.candidates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    func project(withID id: UUID) -> HighlightProject? {
        if draft?.id == id { return draft }
        return projects.first { $0.id == id }
    }

    func discardDraft() {
        guard !isExporting else { return }
        draft = nil
    }

    func videoURL(for video: LibraryVideo) -> URL { repository.videoURL(for: video) }

    private func updateVideoMetadata(sourceKey: String, metadata: VideoMetadata?) {
        guard let metadata, let index = videos.firstIndex(where: { $0.fileName == sourceKey }),
              videos[index].metadata != metadata else { return }
        var updatedVideos = videos
        updatedVideos[index].metadata = metadata
        do {
            try repository.saveVideos(updatedVideos)
            videos = updatedVideos
        } catch let error as RepositoryError {
            repositoryLoadErrorMessage = error.localizedDescription
        } catch { /* The video and analysis remain usable; metadata can be refreshed on retry. */ }
    }

    func videoSource(for video: LibraryVideo) -> VideoSourceReference {
        if let identifier = video.photoAssetIdentifier { return .photoLibrary(localIdentifier: identifier) }
        return .appFile(repository.videoURL(for: video))
    }

    func videoURL(for project: HighlightProject) -> URL {
        repository.videoURL(for: project)
    }

    func videoSource(for project: HighlightProject) -> VideoSourceReference {
        if let identifier = project.sourcePhotoAssetIdentifier { return .photoLibrary(localIdentifier: identifier) }
        return .appFile(repository.videoURL(for: project))
    }

    func outputURL(for project: HighlightProject) -> URL? {
        repository.exportURL(for: project)
    }

    func updateSelection(projectID: UUID, candidateID: UUID, selected: Bool) {
        guard !isExporting, draft?.id == projectID,
              let candidateIndex = draft?.candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        draft?.candidates[candidateIndex].isSelected = selected
        draft?.candidates[candidateIndex].hasManualSelectionOverride = true
        if let source = draft?.sourceFileName,
           let resultIndex = analysisJobs[source]?.result?.candidates.firstIndex(where: { $0.id == candidateID }) {
            analysisJobs[source]?.result?.candidates[resultIndex].isSelected = selected
            analysisJobs[source]?.result?.candidates[resultIndex].hasManualSelectionOverride = true
            persistAnalyses()
        } else if let source = draft?.sourceFileName,
                  let index = analysisJobs[source]?.manualCandidates?.firstIndex(where: { $0.id == candidateID }) {
            analysisJobs[source]?.manualCandidates?[index].isSelected = selected
            analysisJobs[source]?.manualCandidates?[index].hasManualSelectionOverride = true
            persistAnalyses()
        }
    }

    func updateSelectionForAll(projectID: UUID, selected: Bool) {
        guard !isExporting, var project = draft, project.id == projectID else { return }
        for index in project.candidates.indices {
            project.candidates[index].isSelected = selected
            project.candidates[index].hasManualSelectionOverride = true
        }
        draft = project

        guard var job = analysisJobs[project.sourceFileName] else { return }
        if var result = job.result {
            for index in result.candidates.indices {
                result.candidates[index].isSelected = selected
                result.candidates[index].hasManualSelectionOverride = true
            }
            job.result = result
        }
        if var manualCandidates = job.manualCandidates {
            for index in manualCandidates.indices {
                manualCandidates[index].isSelected = selected
                manualCandidates[index].hasManualSelectionOverride = true
            }
            job.manualCandidates = manualCandidates
        }
        analysisJobs[project.sourceFileName] = job
        persistAnalyses()
    }

    @discardableResult
    func addManualHighlight(projectID: UUID, at time: TimeInterval) throws -> (candidate: ShotCandidate, inserted: Bool)? {
        guard !isExporting, var project = draft, project.id == projectID,
              time.isFinite, project.duration > 0,
              var job = analysisJobs[project.sourceFileName], !job.status.isActive else { return nil }
        let eventTime = min(project.duration, max(0, time))
        // Debounce repeated taps at the same moment without hiding nearby AI suggestions.
        if let existing = job.manualCandidates?.first(where: { abs($0.eventTime - eventTime) < 0.5 }) {
            return (existing, false)
        }
        let candidate = ShotCandidate(eventTime: eventTime, confidence: 1, origin: .manual)
        job.manualCandidates = (job.manualCandidates ?? []) + [candidate]
        job.status = .ready
        var updated = analysisJobs
        updated[project.sourceFileName] = job
        try repository.saveAnalyses(updated)
        project.candidates = job.reviewCandidates
        analysisJobs = updated
        draft = project
        return (candidate, true)
    }

    func removeHighlightCandidate(projectID: UUID, candidateID: UUID) throws {
        guard !isExporting, var project = draft, project.id == projectID,
              var job = analysisJobs[project.sourceFileName],
              project.candidates.contains(where: { $0.id == candidateID }) else { return }
        job.manualCandidates?.removeAll { $0.id == candidateID }
        job.result?.candidates.removeAll { $0.id == candidateID }
        job.status = job.candidateCount == 0 ? .empty : .ready
        var updated = analysisJobs
        updated[project.sourceFileName] = job
        try repository.saveAnalyses(updated)
        project.candidates = job.reviewCandidates
        analysisJobs = updated
        draft = project
    }

    @discardableResult
    func createHighlight(projectID: UUID) async throws -> HighlightProject {
        guard !isExporting else { throw CompositionError.exportInProgress }
        guard let project = draft, project.id == projectID else { throw CompositionError.missingDraft }
        guard !project.mergedClipRanges.isEmpty else { throw CompositionError.noClips }
        let outputURL = try repository.createExportURL()
        isExporting = true
        defer { isExporting = false }
        do {
            try await compositionService.createHighlight(
                from: project, source: videoSource(for: project), outputURL: outputURL
            )
            try Task.checkCancellation()
            let asset = AVURLAsset(url: outputURL)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw CompositionError.exportFailed }
            try Task.checkCancellation()
            var completed = project
            completed.title = String(localized: "\(project.title) · Shot Highlights", bundle: AppLanguage.current.bundle)
            completed.outputFileName = outputURL.lastPathComponent
            completed.outputDuration = duration
            completed.createdAt = .now
            let updated = [completed] + projects
            try repository.saveProjects(updated)
            projects = updated
            draft = nil
            return completed
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func saveSelectedHighlightsToPhotos(projectID: UUID) async throws {
        guard !isExporting else { throw CompositionError.exportInProgress }
        guard let project = draft, project.id == projectID else { throw CompositionError.missingDraft }
        let selectedCandidates = project.selectedCandidates
        guard !selectedCandidates.isEmpty else { throw CompositionError.noClips }
        isExporting = true
        defer { isExporting = false }
        let source = videoSource(for: project)
        for candidate in selectedCandidates {
            try Task.checkCancellation()
            let outputURL = try repository.createExportURL()
            do {
                try await compositionService.createClip(
                    from: project, candidate: candidate, source: source, outputURL: outputURL
                )
                try Task.checkCancellation()
                try await compositionService.saveToPhotos(url: outputURL)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    func deleteVideo(_ video: LibraryVideo) throws {
        guard !isExporting else { throw CompositionError.exportInProgress }
        cancelAnalysis(videoID: video.id)
        let checkpointFileName = analysisJobs[video.id]?.checkpointFileName
        let remaining = videos.filter { $0.id != video.id }
        try repository.deleteVideo(video, remainingVideos: remaining)
        videos = remaining
        analysisJobs.removeValue(forKey: video.id)
        if persistAnalyses() { repository.removeAnalysisCheckpoint(fileName: checkpointFileName) }
        if draft?.sourceFileName == video.fileName { draft = nil }
        if activeVideo?.sourceKey == video.fileName { activeVideo = nil }
    }

    func deleteHighlight(_ project: HighlightProject) throws {
        guard !isExporting else { throw CompositionError.exportInProgress }
        let remaining = projects.filter { $0.id != project.id }
        try repository.deleteProject(project, remainingProjects: remaining)
        projects = remaining
    }

    func saveToPhotos(projectID: UUID) async throws {
        guard let project = project(withID: projectID), let outputURL = outputURL(for: project) else {
            throw CompositionError.exportFailed
        }
        try await compositionService.saveToPhotos(url: outputURL)
    }
}
