import Foundation

struct ImageRegion: Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    static let full = ImageRegion(x: 0, y: 0, width: 1, height: 1)
}

enum BasketImageGeometry {
    /// Undo .scaleFit's centered padding BEFORE mapping a crop into its source.
    static func imageObject(_ box: BasketballObject, imageWidth: Double, imageHeight: Double,
                            region: ImageRegion = .full) -> BasketballObject? {
        guard box.isValid, imageWidth.isFinite, imageHeight.isFinite, imageWidth > 0, imageHeight > 0,
              [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite),
              region.width > 0, region.height > 0 else { return nil }
        let scale = min(1280 / imageWidth, 736 / imageHeight)
        let padX = (1280 - imageWidth * scale) / 2
        let padY = (736 - imageHeight * scale) / 2
        let x1 = (box.x1 - padX) / (scale * imageWidth)
        let x2 = (box.x2 - padX) / (scale * imageWidth)
        let y1 = (box.y1 - padY) / (scale * imageHeight)
        let y2 = (box.y2 - padY) / (scale * imageHeight)
        guard (0...1).contains((x1 + x2) / 2), (0...1).contains((y1 + y2) / 2) else { return nil }
        let result = BasketballObject(classID: box.classID, confidence: box.confidence,
            x1: region.x + max(0, x1) * region.width, y1: region.y + max(0, y1) * region.height,
            x2: region.x + min(1, x2) * region.width, y2: region.y + min(1, y2) * region.height)
        return result.isValid ? result : nil
    }

    static func crop(around rim: BasketballObject, imageWidth: Double, imageHeight: Double) -> ImageRegion? {
        guard rim.isValid, rim.confidence >= 0.20, rim.width <= 0.12,
              imageWidth > 0, imageHeight > 0 else { return nil }
        let side = max(rim.width * imageWidth * 6,
                       max(rim.height * imageHeight * 8, min(imageWidth, imageHeight) * 0.28))
        let x1 = max(0, rim.midX * imageWidth - side / 2)
        let y1 = max(0, rim.midY * imageHeight - side / 2)
        let x2 = min(imageWidth, rim.midX * imageWidth + side / 2)
        let y2 = min(imageHeight, rim.midY * imageHeight + side / 2)
        guard x2 - x1 >= 24, y2 - y1 >= 24 else { return nil }
        return ImageRegion(x: x1 / imageWidth, y: y1 / imageHeight,
                           width: (x2 - x1) / imageWidth, height: (y2 - y1) / imageHeight)
    }

    static func deduplicated(_ objects: [BasketballObject]) -> [BasketballObject] {
        var kept: [BasketballObject] = []
        for object in objects.filter(\.isValid).sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { previous in
                guard previous.classID == object.classID else { return false }
                let intersection = max(0, min(previous.x2, object.x2) - max(previous.x1, object.x1)) *
                    max(0, min(previous.y2, object.y2) - max(previous.y1, object.y1))
                let union = previous.width * previous.height + object.width * object.height - intersection
                return union > 0 && intersection / union >= 0.4
            }
            if !duplicate { kept.append(object) }
        }
        // Bound checkpoint size and trajectory search cost. Keep each class so
        // an overconfident static target cannot evict all ball/rim observations.
        return (0...2).flatMap { classID in Array(kept.filter { $0.classID == classID }.prefix(4)) }
    }
}

/// Combine full/partial motion with short, strong appearance pulses. Complete
/// ball trajectories are helpful corroboration, not a mandatory class sequence.
struct BasketMotionFilter {
    private struct Point {
        let time: Double
        let x: Double
        let y: Double
        let confidence: Double
        let classID: Int
        let width: Double
    }
    private struct Track {
        var rim: BasketballObject
        var lastTime: Double
        var points: [Point]
    }
    private enum Evidence: Equatable { case full, partial, appearance }
    private struct Proposal {
        let event: ShotEventFilter.Event
        let evidence: Evidence
    }
    private struct Pulse {
        var rim: BasketballObject
        let firstTime: Double
        var lastTime: Double
        var peakTime: Double
        var peakConfidence: Double
        var sumConfidence: Double
        var frames: Int
        var strongFrames: Int
    }
    private var tracks: [Track] = []
    private var proposals: [Proposal] = []
    private var pulse: Pulse?
    private var lastTime: Double?
    private let threshold: Double
    private let imageAspectRatio: Double
    private let minimumPulseSpan: Double
    private let frameInterval: Double

    init(threshold: Double, frameRate: Double? = nil, imageAspectRatio: Double = 1) {
        self.threshold = threshold.isFinite ? min(0.95, max(0.05, threshold)) : 0.55
        self.imageAspectRatio = imageAspectRatio.isFinite && imageAspectRatio > 0 ? imageAspectRatio : 1
        let fps = frameRate.flatMap { $0.isFinite && $0 > 0 ? min(30, $0) : nil } ?? 30
        minimumPulseSpan = max(0.08, 2 / fps)
        frameInterval = 1 / fps
    }

    mutating func append(time: Double, objects: [BasketballObject]) {
        guard time.isFinite, time >= 0 else { return }
        if let lastTime, time <= lastTime { return }
        if let lastTime, time - lastTime > 0.30 {
            tracks.removeAll()
            completePulse()
        }
        lastTime = time
        // Work in source-width units on both axes after undoing model padding.
        let objects = BasketImageGeometry.deduplicated(objects).map {
            BasketballObject(classID: $0.classID, confidence: $0.confidence,
                             x1: $0.x1, y1: $0.y1 * imageAspectRatio,
                             x2: $0.x2, y2: $0.y2 * imageAspectRatio)
        }
        let rims = objects.filter { $0.classID == 1 && $0.confidence >= 0.20 && $0.width >= 0.002 }
        appendAppearance(time: time, objects: objects, rims: rims)
        var nextTracks: [Track] = []
        var usedTracks: Set<Int> = []
        for rim in rims {
            let match = tracks.indices.filter { index in
                !usedTracks.contains(index) && time - tracks[index].lastTime <= 0.22 &&
                    sameRim(tracks[index].rim, rim)
            }.min {
                hypot(tracks[$0].rim.midX - rim.midX, tracks[$0].rim.midY - rim.midY) <
                    hypot(tracks[$1].rim.midX - rim.midX, tracks[$1].rim.midY - rim.midY)
            }
            var track: Track
            if let match { usedTracks.insert(match); track = tracks[match] }
            else { track = Track(rim: rim, lastTime: time, points: []) }
            track.rim = rim
            track.lastTime = time
            track.points.removeAll { time - $0.time > 0.65 }
            let balls = objects.filter {
                guard ($0.classID == 0 || $0.classID == 2),
                      $0.confidence >= max(0.25, threshold - 0.25),
                      $0.width <= rim.width * 2, $0.height <= rim.width * 3 else { return false }
                if $0.classID == 0 {
                    // Keep distant/blurred balls, while excluding thin background
                    // specks. A class-2 box may describe the net rather than ball.
                    return $0.width >= rim.width * 0.05 && $0.width <= rim.width * 1.3 &&
                        (0.25...3).contains($0.height / $0.width)
                }
                return true
            }
            for ball in balls {
                let point = Point(time: time, x: (ball.midX - rim.midX) / rim.width,
                                  y: (ball.midY - rim.midY) / rim.width,
                                  confidence: ball.confidence, classID: ball.classID, width: ball.width / rim.width)
                guard abs(point.x) <= 1.2, point.y >= -2.5, point.y <= 2 else { continue }
                if let proposal = partial(endingAt: point, points: track.points) { proposals.append(proposal) }
                if point.y >= 0.25, abs(point.x) <= 0.65,
                   let proposal = passage(endingAt: point, points: track.points) { proposals.append(proposal) }
                track.points.append(point)
            }
            nextTracks.append(track)
        }
        // A missing rim for one or two frames must not erase the ball's approach.
        // Do not fabricate observations or update lastTime for retained tracks.
        for index in tracks.indices where !usedTracks.contains(index) && time - tracks[index].lastTime <= 0.18 {
            nextTracks.append(tracks[index])
        }
        tracks = Array(nextTracks.prefix(8))
    }

    private func sameRim(_ a: BasketballObject, _ b: BasketballObject) -> Bool {
        let ratio = b.width / a.width
        return (0.55...1.8).contains(ratio) &&
            abs(a.midX - b.midX) <= max(0.012, b.width * 1.3) &&
            abs(a.midY - b.midY) <= max(0.012, b.width * 1.3)
    }

    private func isTarget(_ point: Point) -> Bool {
        point.classID == 2 && point.confidence >= threshold && abs(point.x) <= 0.6 &&
            point.y >= -0.65 && point.y <= 0.85
    }

    private func partial(endingAt end: Point, points: [Point]) -> Proposal? {
        for start in points.reversed() where start.time < end.time && end.time - start.time <= 0.30 {
            let approach = start.classID == 0 && start.y <= -0.25 && isTarget(end)
            let exit = isTarget(start) && end.classID == 0 && end.y >= 0.25
            guard approach || exit, end.time - start.time >= 0.02,
                  end.y - start.y >= 0.25, end.y - start.y <= 2,
                  abs(end.x - start.x) <= 0.55,
                  (0.2...5).contains(end.width / start.width) else { continue }
            let target = approach ? end : start
            return Proposal(event: .init(time: target.time, confidence: target.confidence,
                                          supportingFrames: 2, requiresReview: true), evidence: .partial)
        }
        return nil
    }

    private func passage(endingAt end: Point, points: [Point]) -> Proposal? {
        for middle in points.reversed() where middle.time < end.time && end.time - middle.time <= 0.25 {
            guard isTarget(middle), end.y - middle.y >= 0.08, end.y - middle.y <= 1.8,
                  abs(end.x - middle.x) <= 0.65,
                  (0.2...5).contains(end.width / middle.width) else { continue }
            for start in points.reversed() where start.time < middle.time && middle.time - start.time <= 0.25 {
                guard start.y <= -0.25, middle.y - start.y >= 0.08, middle.y - start.y <= 1.8,
                      abs(start.x) <= 0.8, abs(middle.x - start.x) <= 0.65,
                      (0.2...5).contains(middle.width / start.width),
                      end.time - start.time >= 0.04, end.time - start.time <= 0.60,
                      start.classID == 0 || end.classID == 0 else { continue }
                let fraction = -start.y / (end.y - start.y)
                let crossingX = start.x + (end.x - start.x) * fraction
                guard abs(crossingX) <= 0.5 else { continue }
                let timeFraction = (middle.time - start.time) / (end.time - start.time)
                let predictedX = start.x + (end.x - start.x) * timeFraction
                let predictedY = start.y + (end.y - start.y) * timeFraction
                guard hypot(middle.x - predictedX, middle.y - predictedY) <= 0.75 else { continue }
                let full = start.classID == 0 && end.classID == 0
                return Proposal(event: .init(time: middle.time, confidence: middle.confidence,
                                              supportingFrames: 3, requiresReview: !full),
                                evidence: full ? .full : .partial)
            }
        }
        return nil
    }

    private mutating func appendAppearance(time: Double, objects: [BasketballObject], rims: [BasketballObject]) {
        if let pulse, time - pulse.lastTime > 0.30 { completePulse() }
        var best: (BasketballObject, BasketballObject)?
        for rim in rims {
            for target in objects where target.classID == 2 && target.confidence >= max(0.35, threshold - 0.10) {
                let x = (target.midX - rim.midX) / rim.width
                let y = (target.midY - rim.midY) / rim.width
                guard abs(x) <= 0.65, y >= -0.7, y <= 1.3,
                      target.width <= rim.width * 2, target.height <= rim.width * 3 else { continue }
                if best == nil || target.confidence > best!.0.confidence { best = (target, rim) }
            }
        }
        guard let (target, rim) = best else { return }
        if let pulse, !sameRim(pulse.rim, rim) { completePulse() }
        if var current = pulse {
            current.rim = rim
            current.lastTime = time
            current.frames += 1
            current.sumConfidence += target.confidence
            if target.confidence >= threshold { current.strongFrames += 1 }
            if target.confidence > current.peakConfidence { current.peakConfidence = target.confidence; current.peakTime = time }
            pulse = current
        } else {
            pulse = Pulse(rim: rim, firstTime: time, lastTime: time, peakTime: time,
                          peakConfidence: target.confidence, sumConfidence: target.confidence,
                          frames: 1, strongFrames: target.confidence >= threshold ? 1 : 0)
        }
    }

    private func appearanceProposal(_ pulse: Pulse) -> Proposal? {
        let span = pulse.lastTime - pulse.firstTime
        guard pulse.frames >= 4, pulse.strongFrames >= 3,
              span >= minimumPulseSpan, span <= 1.0,
              Double(pulse.frames - 1) * frameInterval / span >= 0.45,
              pulse.peakConfidence >= min(0.95, max(0.65, threshold + 0.05)),
              pulse.sumConfidence / Double(pulse.frames) >= min(0.95, threshold + 0.05) else { return nil }
        return Proposal(event: .init(time: pulse.peakTime, confidence: pulse.peakConfidence,
                                      supportingFrames: pulse.frames, requiresReview: true), evidence: .appearance)
    }

    private mutating func completePulse() {
        if let pulse, let proposal = appearanceProposal(pulse) { proposals.append(proposal) }
        pulse = nil
    }

    private func resolved() -> [Proposal] {
        var all = proposals
        if let pulse, let proposal = appearanceProposal(pulse) { all.append(proposal) }
        let ranked = all.sorted {
            if $0.event.requiresReview != $1.event.requiresReview { return !$0.event.requiresReview }
            if $0.event.confidence != $1.event.confidence { return $0.event.confidence > $1.event.confidence }
            if $0.event.supportingFrames != $1.event.supportingFrames { return $0.event.supportingFrames > $1.event.supportingFrames }
            return $0.event.time < $1.event.time
        }
        var kept: [Proposal] = []
        for proposal in ranked where kept.allSatisfy({ abs($0.event.time - proposal.event.time) >= 1.5 }) { kept.append(proposal) }
        return kept.sorted { $0.event.time < $1.event.time }
    }

    var currentEvents: [ShotEventFilter.Event] { resolved().map(\.event) }
    mutating func finish() -> [ShotEventFilter.Event] { completePulse(); return currentEvents }
    var evidenceCounts: [String: Int] {
        let values = resolved()
        return ["fullMotion": values.filter { $0.evidence == .full }.count,
                "partialMotion": values.filter { $0.evidence == .partial }.count,
                "strongAppearance": values.filter { $0.evidence == .appearance }.count]
    }
}

/// Small, local diagnostic report: object coverage, confidence distribution and
/// representative detections. No images, audio or video are included.
struct BasketAnalysisDiagnostics: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let time: Double
        let targetConfidence: Double
        let objects: [BasketballObject]
    }
    var processedFrames = 0
    var framesWithBall = 0
    var framesWithRim = 0
    var framesWithTarget = 0
    var framesWithTargetAtRim = 0
    var framesAtThreshold = 0
    var peakTargetConfidence: Double = 0
    var peakNearRimConfidence: Double = 0
    var targetConfidenceHistogram = Array(repeating: 0, count: 10)
    var evidenceCounts: [String: Int] = [:]
    var sampleFrames: [Frame] = []

    mutating func append(time: Double, objects: [BasketballObject], threshold: Double, imageAspectRatio: Double) {
        guard time.isFinite, time >= 0 else { return }
        let valid = objects.filter(\.isValid)
        processedFrames += 1
        if valid.contains(where: { $0.classID == 0 && $0.confidence >= 0.25 }) { framesWithBall += 1 }
        if valid.contains(where: { $0.classID == 1 && $0.confidence >= 0.20 }) { framesWithRim += 1 }
        let score = valid.filter { $0.classID == 2 }.map(\.confidence).max() ?? 0
        let near = BasketSpatialGate.confidence(in: valid, imageAspectRatio: imageAspectRatio)
        if score > 0 { framesWithTarget += 1 }
        if near > 0 { framesWithTargetAtRim += 1 }
        if near >= threshold { framesAtThreshold += 1 }
        peakTargetConfidence = max(peakTargetConfidence, score)
        peakNearRimConfidence = max(peakNearRimConfidence, near)
        targetConfidenceHistogram[min(9, max(0, Int(score * 10)))] += 1
        let sample = Frame(time: time, targetConfidence: score, objects: valid)
        if let last = sampleFrames.last, Int(last.time / 10) == Int(time / 10) {
            if score > last.targetConfidence { sampleFrames[sampleFrames.count - 1] = sample }
        } else if sampleFrames.count < 120 { sampleFrames.append(sample) }
    }
}
