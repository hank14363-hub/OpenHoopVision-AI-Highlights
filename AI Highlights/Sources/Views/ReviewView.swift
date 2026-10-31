import AVFoundation
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ReviewView: View {
    let projectID: UUID
    let onGenerated: () -> Void
    let onRetry: () -> Void

    @Environment(AppModel.self) private var model
    @State private var filter: HighlightFilter = .all
    @State private var sort: HighlightSort = .timeAscending
    @State private var player = AVPlayer()
    @State private var activeCandidateID: UUID?
    @State private var isPlayerPlaying = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var pendingAutoplay = false
    @State private var isGenerating = false
    @State private var isDownloading = false
    @State private var generationTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var errorTitle = String(localized: "Unable to Create Highlights", bundle: AppLanguage.current.bundle)
    @State private var manualFeedback: String?
    @State private var manualFeedbackTask: Task<Void, Never>?
    @State private var revealedClipRow: String?
    @State private var isExportingDiagnostics = false
    @State private var diagnosticDocument = AnalysisDiagnosticDocument(data: Data())

    private var project: HighlightProject? { model.project(withID: projectID) }
    private var allowsThumbnails: Bool { !model.hasActiveAnalyses }
    private var isBusy: Bool { isGenerating || isDownloading }

    var body: some View {
        reviewPage
    }

    private var reviewPage: some View {
        observedReviewPage
            .fileExporter(isPresented: $isExportingDiagnostics, document: diagnosticDocument,
                          contentType: .json, defaultFilename: "AI_Highlights_Diagnostics") { result in
                if case .failure(let error) = result {
                    errorTitle = String(localized: "Unable to Export Diagnostics", bundle: AppLanguage.current.bundle)
                    errorMessage = error.localizedDescription
                }
            }
            .alert(errorTitle, isPresented: isErrorPresented) {
                Button(String(localized: "OK", bundle: AppLanguage.current.bundle), role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? String(localized: "Please try again.", bundle: AppLanguage.current.bundle))
            }
    }

    private var observedReviewPage: some View {
        navigationReviewPage
            .onDisappear(perform: stopPlaybackAndTasks)
            .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { (status: AVPlayer.TimeControlStatus) in
                isPlayerPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
            }
            .onChange(of: filter) { _, _ in revealedClipRow = nil }
            .onChange(of: sort) { _, _ in revealedClipRow = nil }
    }

    private var navigationReviewPage: some View {
        AnyView(reviewScreen)
            .hoopScreen()
            .navigationTitle(String(localized: "High Moments", bundle: AppLanguage.current.bundle))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isBusy)
            .toolbar { retryToolbar }
    }

    @ToolbarContentBuilder
    private var retryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                do {
                    diagnosticDocument = AnalysisDiagnosticDocument(data: try model.analysisDiagnosticData(projectID: projectID))
                    isExportingDiagnostics = true
                } catch {
                    errorTitle = String(localized: "Unable to Export Diagnostics", bundle: AppLanguage.current.bundle)
                    errorMessage = error.localizedDescription
                }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .accessibilityLabel(String(localized: "Export Analysis Diagnostics", bundle: AppLanguage.current.bundle))
            .accessibilityIdentifier("review.exportDiagnostics")
            .disabled(isBusy)
            AnalysisRetryButton(size: 36, action: onRetry)
                .disabled(isBusy)
                .accessibilityIdentifier("review.retry")
        }
    }

    private var isErrorPresented: Binding<Bool> {
        Binding<Bool>(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func stopPlaybackAndTasks() {
        player.pause()
        isPlayerPlaying = false
        player.replaceCurrentItem(with: nil)
        playbackTask?.cancel()
        generationTask?.cancel()
        downloadTask?.cancel()
        manualFeedbackTask?.cancel()
    }

    @ViewBuilder
    private var reviewScreen: some View {
        if let project {
            reviewContent(project)
        } else {
            ContentUnavailableView(
                String(localized: "Video not found", bundle: AppLanguage.current.bundle),
                systemImage: "video.slash"
            )
        }
    }

    private func reviewContent(_ project: HighlightProject) -> some View {
        // Derive these values once for this render; do not keep a separate cache that can become stale.
        let visible = visibleCandidates(project)
        let uncertain = uncertainCount(project)
        let selectedCount = project.selectedCandidateCount
        let selectedDuration = project.selectedDuration

        return VStack(spacing: 0) {
            reviewHeader(project: project, uncertainCount: uncertain, selectedCount: selectedCount)
            clipList(project: project, visible: visible)
        }
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionFooter(project: project, selectedCount: selectedCount, duration: selectedDuration)
                .padding(.bottom, -15)
        }
        .disabled(isBusy)
        .onAppear {
            configurePlayback(project: project, candidate: project.candidates.first, autoplay: false)
        }
    }

    private func reviewHeader(project: HighlightProject, uncertainCount: Int, selectedCount: Int) -> some View {
        VStack(spacing: 12) {
            playerCard(project)
                .fixedSize(horizontal: false, vertical: true)
            filterBar(totalCount: project.candidates.count, uncertainCount: uncertainCount, selectedCount: selectedCount)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .background(Color.hoopInk)
        .zIndex(1)
    }

    private func clipList(project: HighlightProject, visible: [IndexedCandidate]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 1).id("review.clipList.top")
                    ForEach(visible) { indexed in
                        candidateSwipeRow(indexed, project: project)
                    }
                    if visible.isEmpty {
                        emptyClipState
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 12)
            }
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .contentMargins(.trailing, -7, for: .scrollIndicators)
            .scrollClipDisabled()
            .padding(.horizontal, 6)
            .accessibilityIdentifier("review.clipList")
            .onChange(of: visible.map(\.id)) { _, _ in
                revealedClipRow = nil
                proxy.scrollTo("review.clipList.top", anchor: .top)
            }
        }
    }

    private func candidateSwipeRow(_ indexed: IndexedCandidate, project: HighlightProject) -> some View {
        let candidate = indexed.candidate
        return SwipeToDeleteRow(
            id: candidate.id.uuidString,
            revealedRow: $revealedClipRow,
            onDelete: { removeHighlight(candidate) },
            deleteLabel: String(localized: "Delete Highlight", bundle: AppLanguage.current.bundle)
        ) {
            candidateRow(
                candidate,
                project: project,
                number: indexed.offset + 1,
                allowsThumbnails: allowsThumbnails
            )
        }
    }

    private var emptyClipState: some View {
        let title: String
        let symbol: String
        switch filter {
        case .uncertain:
            title = String(localized: "No clips need review", bundle: AppLanguage.current.bundle)
            symbol = "checkmark.seal"
        case .selected:
            title = String(localized: "No clips selected", bundle: AppLanguage.current.bundle)
            symbol = "checkmark.circle"
        case .all:
            title = String(localized: "No highlight clips", bundle: AppLanguage.current.bundle)
            symbol = "checkmark.circle"
        }
        return ContentUnavailableView(title, systemImage: symbol)
    }

    private func playerTitle(_ candidate: ShotCandidate?, number: Int) -> String {
        guard let candidate else { return String(localized: "Original video", bundle: AppLanguage.current.bundle) }
        if candidate.needsVisualReview { return String(localized: "Visual candidate · Needs confirmation", bundle: AppLanguage.current.bundle) }
        if candidate.isScoreboard { return String(localized: "Score change · Check timing", bundle: AppLanguage.current.bundle) }
        if candidate.isManual { return String(localized: "Manual highlight \(number)", bundle: AppLanguage.current.bundle) }
        return String(localized: "Highlight \(number) · \(candidate.confidence.formatted(.percent.precision(.fractionLength(0))))", bundle: AppLanguage.current.bundle)
    }

    private func candidateLabel(_ candidate: ShotCandidate, uncertain: Bool) -> String {
        if candidate.needsVisualReview { return String(localized: "Visual candidate · Needs confirmation", bundle: AppLanguage.current.bundle) }
        if candidate.isScoreboard { return String(localized: "Score change · Check timing", bundle: AppLanguage.current.bundle) }
        if candidate.isManual { return String(localized: "Manual", bundle: AppLanguage.current.bundle) }
        let label = uncertain ? String(localized: "Uncertain", bundle: AppLanguage.current.bundle) : "AI"
        return "\(label) · \(candidate.confidence.formatted(.percent.precision(.fractionLength(0))))"
    }

    private func playerCard(_ project: HighlightProject) -> some View {
        let candidate = project.candidates.first { $0.id == activeCandidateID }
        let range = candidate.map { project.clipRange(for: $0) } ?? ClipRange(start: 0, end: project.duration)
        let number = candidate.flatMap { value in project.candidates.firstIndex { $0.id == value.id } }.map { $0 + 1 }
        return VStack(spacing: 0) {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .accessibilityIdentifier("review.previewPlayer")
                .overlay(alignment: .top) {
                    HStack {
                        Text(playerTitle(candidate, number: number ?? 1))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.68), in: Capsule())
                            .allowsHitTesting(false)
                        Spacer()
                        Button { configurePlayback(project: project, candidate: nil, autoplay: true) } label: {
                            Label(String(localized: "Play Original", bundle: AppLanguage.current.bundle), systemImage: "play.rectangle")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(.black.opacity(0.68), in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.playOriginal")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.top, 3)
                }
            HStack {
                if let candidate {
                    Text(range.start.highlightTimestamp)
                    Spacer()
                    Text(candidate.eventTime.highlightTimestamp).foregroundStyle(Color.hoopOrange)
                    Spacer()
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(playbackTime(project).highlightTimestamp)
                    }
                    .frame(width: 58, alignment: .leading)
                    Spacer(minLength: 6)
                    Button { addManualHighlight(project) } label: {
                        Label(manualFeedback ?? String(localized: "Add Highlight", bundle: AppLanguage.current.bundle), systemImage: manualFeedback == nil ? "plus" : "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.hoopOrange)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.hoopOrange.opacity(0.13), in: Capsule())
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Add a highlight at the current playback time", bundle: AppLanguage.current.bundle))
                    .accessibilityIdentifier("review.addManualHighlight")
                    Spacer(minLength: 6)
                }
                Text(range.end.highlightTimestamp)
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.hoopMuted)
            .padding(.horizontal, 13).frame(minHeight: candidate == nil ? 44 : 36)
        }
        .background(Color.hoopPanel, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.hoopStroke, lineWidth: 1) }
    }

    private func configurePlayback(project: HighlightProject, candidate: ShotCandidate?, autoplay: Bool) {
        playbackTask?.cancel()
        player.pause()
        isPlayerPlaying = false
        pendingAutoplay = false
        do { try PlaybackAudioSession.prepare(player) }
        catch {
            errorTitle = String(localized: "Unable to Play Video", bundle: AppLanguage.current.bundle)
            errorMessage = error.localizedDescription
            return
        }
        activeCandidateID = candidate?.id
        let range = candidate.map { project.clipRange(for: $0) } ?? ClipRange(start: 0, end: project.duration)
        let source = model.videoSource(for: project)
        pendingAutoplay = autoplay
        playbackTask = Task {
            defer {
                pendingAutoplay = false
            }
            do {
                let item = try await source.playerItem()
                guard !Task.isCancelled else { return }
                if candidate != nil { item.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600) }
                player.replaceCurrentItem(with: item)
            let didSeek = await player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard didSeek, !Task.isCancelled else { return }
                if autoplay { player.play() }
            } catch is CancellationError {
                return
            } catch {
                errorTitle = String(localized: "Unable to Play Video", bundle: AppLanguage.current.bundle)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func filterBar(totalCount: Int, uncertainCount: Int, selectedCount: Int) -> some View {
        HStack(spacing: 7) {
            filterChip(.all, count: totalCount)
            filterChip(.uncertain, count: uncertainCount)
            filterChip(.selected, count: selectedCount)
            Spacer(minLength: 0)
            Menu {
                Picker(String(localized: "Sort", bundle: AppLanguage.current.bundle), selection: $sort) {
                    ForEach(HighlightSort.allCases) { value in Text(value.label).tag(value) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40, height: 44)
                    .background(Color.hoopPanel, in: RoundedRectangle(cornerRadius: 13))
            }
            .accessibilityLabel(String(localized: "Sort clips", bundle: AppLanguage.current.bundle))
        }
        .foregroundStyle(.white)
    }

    private func filterChip(_ value: HighlightFilter, count: Int) -> some View {
        Button { filter = value } label: {
            HStack(spacing: 5) {
                Text(value.label)
                Text(verbatim: count.formatted(.number.grouping(.never).locale(AppLanguage.current.locale))).fontWeight(.bold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(filter == value ? Color.hoopElevated : Color.hoopPanel, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(filter == value ? Color.white.opacity(0.25) : Color.hoopStroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == value ? [.isSelected] : [])
        .accessibilityIdentifier("review.filter.\(value.id)")
    }

    private func candidateRow(_ candidate: ShotCandidate, project: HighlightProject, number: Int, allowsThumbnails: Bool) -> some View {
        let range = project.clipRange(for: candidate)
        let uncertain = isUncertain(candidate)
        let isPlaying = activeCandidateID == candidate.id && isPlayerPlaying
        return HStack(spacing: 10) {
            Button {
                guard revealedClipRow == nil else { revealedClipRow = nil; return }
                if activeCandidateID == candidate.id,
                   isPlayerPlaying || pendingAutoplay {
                    playbackTask?.cancel()
                    pendingAutoplay = false
                    player.pause()
                    isPlayerPlaying = false
                } else {
                    configurePlayback(project: project, candidate: candidate, autoplay: true)
                }
            } label: {
                HStack(spacing: 11) {
                    VideoThumbnailView(videoSource: model.videoSource(for: project), allowsGeneration: allowsThumbnails, timestamp: candidate.eventTime, width: 84, height: 44)
                        .overlay {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.68), in: Circle())
                                .shadow(color: .black, radius: 3)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Text(String(format: String(localized: "%.1f s", bundle: AppLanguage.current.bundle), locale: Locale.current, range.duration))
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                                .padding(3)
                        }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(String(localized: "Highlight \(number)", bundle: AppLanguage.current.bundle))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(candidateLabel(candidate, uncertain: uncertain))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(uncertain ? Color.yellow : Color.hoopMint)
                        }
                        Text(candidate.eventTime.highlightTimestamp)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.hoopMuted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Play highlight \(number), \(candidate.eventTime.highlightTimestamp)", bundle: AppLanguage.current.bundle))
            .accessibilityIdentifier("review.play.\(number)")
            Button {
                model.updateSelection(projectID: project.id, candidateID: candidate.id, selected: !candidate.isSelected)
            } label: {
                Image(systemName: candidate.isSelected ? "checkmark" : "plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(candidate.isSelected ? Color.hoopMint : Color.white.opacity(0.65))
                    .frame(width: 44, height: 44)
                    .background(candidate.isSelected ? Color.hoopMint.opacity(0.14) : Color.white.opacity(0.07), in: Circle())
                    .overlay { Circle().stroke(candidate.isSelected ? Color.hoopMint.opacity(0.3) : Color.white.opacity(0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(candidate.isSelected ? String(localized: "Deselect highlight \(number)", bundle: AppLanguage.current.bundle) : String(localized: "Select highlight \(number)", bundle: AppLanguage.current.bundle))
            .accessibilityIdentifier("review.select.\(number)")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isPlaying ? Color.hoopOrange.opacity(0.11) : (candidate.isSelected ? Color.hoopMint.opacity(0.06) : Color.hoopPanel), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isPlaying ? Color.hoopOrange.opacity(0.9) : (uncertain ? Color.yellow.opacity(0.4) : (candidate.isSelected ? Color.hoopMint.opacity(0.35) : Color.hoopStroke)), lineWidth: isPlaying ? 1.5 : 1)
        }
    }

    private func selectionFooter(project: HighlightProject, selectedCount: Int, duration: TimeInterval) -> some View {
        let allSelected = selectedCount > 0 && selectedCount == project.candidates.count
        return HStack(spacing: 6) {
            Button {
                model.updateSelectionForAll(projectID: project.id, selected: !allSelected)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: allSelected ? "checkmark.square.fill" : (selectedCount > 0 ? "minus.square.fill" : "square"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(String(localized: allSelected ? "Clear all" : "Select all", bundle: AppLanguage.current.bundle))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.hoopOrange)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(project.candidates.isEmpty || isBusy)
            .accessibilityLabel(String(localized: allSelected ? "Deselect all clips" : "Select all clips", bundle: AppLanguage.current.bundle))
            .accessibilityIdentifier("review.selectAll")
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Selected: \(selectedCount)", bundle: AppLanguage.current.bundle)).font(.system(size: 11, weight: .bold))
                Text(duration.highlightDuration)
                    .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Color.hoopMuted)
            }
            Spacer(minLength: 0)
            Button { downloadSelectedHighlights() } label: {
                HStack(spacing: 4) {
                    if isDownloading { ProgressView().tint(Color.hoopOrange) }
                    else { Image(systemName: "arrow.down.to.line") }
                    Text(isDownloading ? String(localized: "Downloading…", bundle: AppLanguage.current.bundle) : String(localized: "Download", bundle: AppLanguage.current.bundle))
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 8)
                .frame(height: 44)
                .foregroundStyle(Color.hoopOrange)
                .background(Color.hoopOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.hoopOrange.opacity(0.7), lineWidth: 1) }
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .disabled(duration <= 0 || isBusy)
            .opacity(duration <= 0 ? 0.4 : 1)
            .accessibilityLabel(String(localized: "Download selected highlights", bundle: AppLanguage.current.bundle))
            .accessibilityIdentifier("review.download")
            Button { generate() } label: {
                HStack(spacing: 7) {
                    if isGenerating { ProgressView().tint(.white) }
                    else { Image(systemName: "film.stack.fill") }
                    Text(isGenerating ? String(localized: "Creating…", bundle: AppLanguage.current.bundle) : String(localized: "Create Highlights", bundle: AppLanguage.current.bundle))
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 8)
                .frame(height: 44)
                .background(Color.hoopOrange, in: RoundedRectangle(cornerRadius: 14))
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .disabled(duration <= 0 || isGenerating)
            .opacity(duration <= 0 ? 0.4 : 1)
            .accessibilityIdentifier("review.generate")
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.hoopOrange.opacity(0.09), in: RoundedRectangle(cornerRadius: 21))
        .overlay { RoundedRectangle(cornerRadius: 21).stroke(Color.hoopOrange.opacity(0.35), lineWidth: 1) }
        .padding(.horizontal, 18).padding(.top, 8)
        .background(Color.hoopInk)
    }

    private func uncertainCount(_ project: HighlightProject) -> Int {
        project.candidates.lazy.filter { isUncertain($0) }.count
    }

    private func isUncertain(_ candidate: ShotCandidate) -> Bool {
        !candidate.isManual && (candidate.needsVisualReview || candidate.isScoreboard || candidate.confidence < model.uncertainConfidenceThreshold)
    }

    private func visibleCandidates(_ project: HighlightProject) -> [IndexedCandidate] {
        let indexed = project.candidates.enumerated().map { offset, candidate in
            IndexedCandidate(offset: offset, candidate: candidate)
        }
        let filtered = indexed.filter { indexed in
            let candidate = indexed.candidate
            switch filter {
            case .all: return true
            case .uncertain: return isUncertain(candidate)
            case .selected: return candidate.isSelected
            }
        }
        return filtered.sorted { left, right in
            let lhs = left.candidate
            let rhs = right.candidate
            switch sort {
            case .timeAscending: return lhs.eventTime < rhs.eventTime
            case .timeDescending: return lhs.eventTime > rhs.eventTime
            case .confidence: return lhs.confidence == rhs.confidence ? lhs.eventTime < rhs.eventTime : lhs.confidence > rhs.confidence
            }
        }
    }

    private func playbackTime(_ project: HighlightProject) -> TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? min(project.duration, max(0, seconds)) : 0
    }

    private func addManualHighlight(_ project: HighlightProject) {
        do {
            guard let result = try model.addManualHighlight(projectID: project.id, at: playbackTime(project)) else { return }
            filter = .all
            manualFeedbackTask?.cancel()
            manualFeedback = "\(result.inserted ? String(localized: "Added", bundle: AppLanguage.current.bundle) : String(localized: "Recorded", bundle: AppLanguage.current.bundle)) \(result.candidate.eventTime.highlightTimestamp)"
            manualFeedbackTask = Task {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                manualFeedback = nil
            }
        } catch { errorTitle = String(localized: "Unable to Add Highlight", bundle: AppLanguage.current.bundle); errorMessage = error.localizedDescription }
    }

    private func removeHighlight(_ candidate: ShotCandidate) {
        do {
            try model.removeHighlightCandidate(projectID: projectID, candidateID: candidate.id)
            revealedClipRow = nil
            if activeCandidateID == candidate.id {
                playbackTask?.cancel()
                pendingAutoplay = false
                player.pause()
                isPlayerPlaying = false
                activeCandidateID = nil
                player.currentItem?.forwardPlaybackEndTime = .invalid
            }
        } catch { errorTitle = String(localized: "Unable to Delete Highlight", bundle: AppLanguage.current.bundle); errorMessage = error.localizedDescription }
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        playbackTask?.cancel()
        pendingAutoplay = false
        player.pause()
        isPlayerPlaying = false
        generationTask = Task {
            defer { isGenerating = false; generationTask = nil }
            do {
                try await model.createHighlight(projectID: projectID)
                guard !Task.isCancelled else { return }
                onGenerated()
            } catch is CancellationError { return }
            catch { errorTitle = String(localized: "Unable to Create Highlights", bundle: AppLanguage.current.bundle); errorMessage = error.localizedDescription }
        }
    }

    private func downloadSelectedHighlights() {
        guard !isDownloading, let project else { return }
        isDownloading = true
        playbackTask?.cancel()
        pendingAutoplay = false
        player.pause()
        isPlayerPlaying = false
        downloadTask = Task {
            defer { isDownloading = false; downloadTask = nil }
            do {
                try await model.saveSelectedHighlightsToPhotos(projectID: project.id)
                guard !Task.isCancelled else { return }
                errorTitle = String(localized: "Saved to Photos", bundle: AppLanguage.current.bundle)
                errorMessage = String(localized: "Saved to your photo library.", bundle: AppLanguage.current.bundle)
            } catch is CancellationError { return }
            catch {
                errorTitle = String(localized: "Unable to Download Highlights", bundle: AppLanguage.current.bundle)
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AnalysisDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct IndexedCandidate: Identifiable {
    let offset: Int
    let candidate: ShotCandidate

    var id: UUID { candidate.id }
}

private enum HighlightFilter: String, Identifiable {
    case all = "全部", uncertain = "待复核", selected = "已选"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "All", bundle: AppLanguage.current.bundle)
        case .uncertain: return String(localized: "Uncertain", bundle: AppLanguage.current.bundle)
        case .selected: return String(localized: "Selected", bundle: AppLanguage.current.bundle)
        }
    }
}
private enum HighlightSort: String, CaseIterable, Identifiable {
    case timeAscending = "时间正序", timeDescending = "时间倒序", confidence = "置信度优先"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timeAscending: return String(localized: "Time: Earliest First", bundle: AppLanguage.current.bundle)
        case .timeDescending: return String(localized: "Time: Latest First", bundle: AppLanguage.current.bundle)
        case .confidence: return String(localized: "Confidence: Highest First", bundle: AppLanguage.current.bundle)
        }
    }
}

