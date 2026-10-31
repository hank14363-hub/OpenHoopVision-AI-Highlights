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

/// A class-2 label near a rim is only appearance evidence. Corroborate it with
/// an ordered above -> rim -> below passage, measured relative to a stable rim.
/// Without this evidence keep the candidate for review, but do not auto-select.
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
    private struct Passage {
        let time: Double
        let confidence: Double
        let hasTarget: Bool
    }
    private var temporal: ShotEventFilter
    private var tracks: [Track] = []
    private var passages: [Passage] = []
    private var lastTime: Double?
    private let threshold: Double
    private let imageAspectRatio: Double

    init(threshold: Double, frameRate: Double? = nil, imageAspectRatio: Double = 1) {
        self.threshold = threshold.isFinite ? min(0.95, max(0.05, threshold)) : 0.55
        self.imageAspectRatio = imageAspectRatio.isFinite && imageAspectRatio > 0 ? imageAspectRatio : 1
        temporal = ShotEventFilter(threshold: threshold, frameRate: frameRate)
    }

    mutating func append(time: Double, objects: [BasketballObject]) {
        guard time.isFinite, time >= 0 else { return }
        if let lastTime, time <= lastTime { return }
        if let lastTime, time - lastTime > 0.25 { tracks.removeAll() }
        lastTime = time
        // Use image-width units on both axes, otherwise normalized y distances
        // in a landscape video are inflated relative to the rim's width.
        let objects = BasketImageGeometry.deduplicated(objects).map {
            BasketballObject(classID: $0.classID, confidence: $0.confidence,
                             x1: $0.x1, y1: $0.y1 * imageAspectRatio,
                             x2: $0.x2, y2: $0.y2 * imageAspectRatio)
        }
        temporal.append(.init(time: time, confidence: BasketSpatialGate.confidence(in: objects)))
        let rims = objects.filter { $0.classID == 1 && $0.confidence >= 0.20 && $0.width >= 0.002 }
        var nextTracks: [Track] = []
        var usedTracks: Set<Int> = []
        for rim in rims {
            let match = tracks.indices.filter { index in
                let previous = tracks[index]
                let widthRatio = rim.width / previous.rim.width
                return !usedTracks.contains(index) && time - previous.lastTime <= 0.20 &&
                    widthRatio >= 0.65 && widthRatio <= 1.55 &&
                    abs(previous.rim.midX - rim.midX) <= max(0.012, rim.width * 1.3) &&
                    abs(previous.rim.midY - rim.midY) <= max(0.012, rim.width * 1.3)
            }.min {
                hypot(tracks[$0].rim.midX - rim.midX, tracks[$0].rim.midY - rim.midY) <
                    hypot(tracks[$1].rim.midX - rim.midX, tracks[$1].rim.midY - rim.midY)
            }
            var track: Track
            if let match {
                usedTracks.insert(match)
                track = tracks[match]
            } else { track = Track(rim: rim, lastTime: time, points: []) }
            track.rim = rim
            track.lastTime = time
            track.points.removeAll { time - $0.time > 0.60 }
            let balls = objects.filter {
                ($0.classID == 0 || $0.classID == 2) && $0.confidence >= max(0.18, threshold - 0.20) &&
                $0.width <= rim.width * 1.35 && $0.height <= rim.width * 1.8
            }
            for ball in balls {
                let point = Point(time: time, x: (ball.midX - rim.midX) / rim.width,
                                  y: (ball.midY - rim.midY) / rim.width,
                                  confidence: ball.confidence, classID: ball.classID, width: ball.width / rim.width)
                guard abs(point.x) <= 1.3, point.y >= -2.5, point.y <= 2 else { continue }
                if point.y >= 0.25, abs(point.x) <= 0.65,
                   let passage = passage(endingAt: point, points: track.points) {
                    if passages.allSatisfy({ abs($0.time - passage.time) >= 1.5 }) { passages.append(passage) }
                }
                track.points.append(point)
            }
            nextTracks.append(track)
        }
        tracks = nextTracks
    }

    private func passage(endingAt end: Point, points: [Point]) -> Passage? {
        for middle in points.reversed() where middle.time < end.time && end.time - middle.time <= 0.18 {
            guard abs(middle.x) <= 0.55, abs(middle.y) <= 0.55,
                  end.y - middle.y >= 0.08, end.y - middle.y <= 1.6,
                  abs(end.x - middle.x) <= 0.65,
                  (0.5...2).contains(end.width / middle.width) else { continue }
            for start in points.reversed() where start.time < middle.time && middle.time - start.time <= 0.18 {
                guard start.y <= -0.25, middle.y - start.y >= 0.08, middle.y - start.y <= 1.6,
                      abs(start.x) <= 0.8, abs(middle.x - start.x) <= 0.65,
                      (0.5...2).contains(middle.width / start.width),
                      end.time - start.time >= 0.04, end.time - start.time <= 0.45 else { continue }
                let evidence = [start, middle, end]
                // Crossing the plane from outside the hoop is a miss, even if
                // the ball later falls below it. Require alignment at the plane.
                let fraction = -start.y / (end.y - start.y)
                let crossingX = start.x + (end.x - start.x) * fraction
                guard abs(crossingX) <= 0.5 else { continue }
                let targetScores = evidence.filter { $0.classID == 2 }.map(\.confidence)
                return Passage(time: middle.time, confidence: targetScores.max() ?? evidence.map(\.confidence).min() ?? 0,
                               hasTarget: !targetScores.isEmpty)
            }
        }
        return nil
    }

    var currentEvents: [ShotEventFilter.Event] { resolved(temporal.currentEvents) }
    mutating func finish() -> [ShotEventFilter.Event] {
        let events = temporal.finish()
        return resolved(events)
    }

    private func resolved(_ visualEvents: [ShotEventFilter.Event]) -> [ShotEventFilter.Event] {
        var events: [ShotEventFilter.Event] = []
        for event in visualEvents {
            let passage = passages.filter { abs($0.time - event.time) <= 0.65 }
                .min { abs($0.time - event.time) < abs($1.time - event.time) }
            events.append(.init(time: passage?.time ?? event.time, confidence: event.confidence,
                                supportingFrames: event.supportingFrames, requiresReview: passage == nil))
        }
        for passage in passages where !events.contains(where: { abs($0.time - passage.time) < 1.5 }) {
            // A brief passage can have just one class-2 frame. Keep it for review
            // even when it cannot satisfy the two-target-frame appearance rule.
            events.append(.init(time: passage.time, confidence: passage.confidence, supportingFrames: 3,
                                requiresReview: !passage.hasTarget || passage.confidence < threshold))
        }
        // Re-anchoring at a passage can move two previously separate appearance
        // peaks together. Prefer corroborated events and suppress duplicates again.
        let ranked = events.sorted {
            if $0.requiresReview != $1.requiresReview { return !$0.requiresReview }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.time < $1.time
        }
        var kept: [ShotEventFilter.Event] = []
        for event in ranked where kept.allSatisfy({ abs($0.time - event.time) >= 1.5 }) { kept.append(event) }
        return kept.sorted { $0.time < $1.time }
    }
}
