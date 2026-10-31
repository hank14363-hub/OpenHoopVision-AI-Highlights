import Foundation

/// Normalized source-image xyxy coordinates, with a top-left origin. Model-space
/// boxes are converted before combining full-frame and crop detections.
struct BasketballObject: Codable, Sendable {
    let classID: Int
    let confidence: Double
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    var width: Double { x2 - x1 }
    var height: Double { y2 - y1 }
    var midX: Double { (x1 + x2) / 2 }
    var midY: Double { (y1 + y2) / 2 }
    var isValid: Bool {
        [confidence, x1, y1, x2, y2].allSatisfy(\.isFinite) &&
        (0...1).contains(confidence) && width > 0 && height > 0
    }
}

enum BasketSpatialGate {
    /// A class-2 label alone is insufficient. Require a detected rim in the same
    /// frame and a plausible target location/size relative to it.
    static func confidence(in objects: [BasketballObject], imageAspectRatio: Double = 1) -> Double {
        let rims = objects.filter { $0.isValid && $0.classID == 1 && $0.confidence >= 0.20 }
        return objects.filter { target in
            guard target.isValid, target.classID == 2 else { return false }
            return rims.contains { rim in
                abs(target.midX - rim.midX) <= rim.width * 1.1 &&
                (target.midY - rim.midY) * imageAspectRatio >= -rim.width * 0.8 &&
                (target.midY - rim.midY) * imageAspectRatio <= rim.width * 1.5 &&
                target.width <= rim.width * 3 && target.height * imageAspectRatio <= rim.width * 4
            }
        }.map(\.confidence).max() ?? 0
    }
}

struct ScoreboardReading: Codable, Equatable, Sendable {
    let left: Int
    let right: Int
    let centerX: Double
    let centerY: Double
    let confidence: Double

    var isValid: Bool {
        (0...199).contains(left) && (0...199).contains(right) &&
        centerX.isFinite && centerY.isFinite && (0...1).contains(centerX) &&
        (0...1).contains(centerY) && confidence.isFinite && (0.65...1).contains(confidence)
    }

    func sameBoard(as other: Self) -> Bool {
        abs(centerX - other.centerX) < 0.12 && abs(centerY - other.centerY) < 0.10
    }

    func sameScore(as other: Self) -> Bool { left == other.left && right == other.right }
}

enum ScoreboardParser {
    /// Coordinates are normalized within the lower video band, with a bottom-left origin.
    struct Token {
        let text: String
        let confidence: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
    }

    /// Crop coordinates use a top-left origin; OCR tokens use bottom-left.
    static func remapped(_ token: Token, cropX: Double, cropTop: Double,
                         cropWidth: Double, cropHeight: Double,
                         bandWidth: Double, bandHeight: Double) -> Token {
        let bottom = bandHeight - cropTop - cropHeight
        return Token(text: token.text, confidence: token.confidence,
                     x: (cropX + token.x * cropWidth) / bandWidth,
                     y: (bottom + token.y * cropHeight) / bandHeight,
                     width: token.width * cropWidth / bandWidth,
                     height: token.height * cropHeight / bandHeight)
    }

    /// Some gym overlays put HOME/GUEST above the two scores instead of placing
    /// team labels on either side. A token is accepted only when both labels are
    /// horizontally aligned with each other and the score pair sits below them.
    private static func hasVerticalLabels(around score: Token, in tokens: [Token], split: (Token, Token)? = nil) -> Bool {
        guard let home = tokens.first(where: { $0.text.uppercased().trimmingCharacters(in: .whitespaces) == "HOME" }),
              let guest = tokens.first(where: { $0.text.uppercased().trimmingCharacters(in: .whitespaces) == "GUEST" }),
              home.midX < guest.midX,
              abs(home.midY - guest.midY) < max(home.height, guest.height) * 1.4 else { return false }
        // Vision coordinates originate at the bottom-left: below means LESS y.
        let labelHeight = max(home.height, guest.height)
        if let (left, right) = split {
            // A period/foul digit between the teams is not the guest score.
            guard abs(left.midX - home.midX) <= max(home.width * 0.7, left.width * 0.5),
                  abs(right.midX - guest.midX) <= max(guest.width * 0.7, right.width * 0.5) else { return false }
        } else {
            guard score.x <= home.midX + home.width * 0.5,
                  score.x + score.width >= guest.midX - guest.width * 0.5 else { return false }
        }
        return score.midY < min(home.midY, guest.midY) &&
            min(home.midY, guest.midY) - score.midY <= labelHeight * 3.5 &&
            score.x >= home.x - labelHeight && score.x + score.width <= guest.x + guest.width + labelHeight
    }

    private static let pairPattern = #"(?<![0-9])([0-9]{1,3})\s*[-–—·•]\s*([0-9]{1,3})(?![0-9])"#

    static func reading(from tokens: [Token]) -> ScoreboardReading? {
        let valid = tokens.filter {
            $0.confidence.isFinite && $0.confidence >= 0.65 &&
            [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0
        }
        let regex = try! NSRegularExpression(pattern: pairPattern)
        var readings: [ScoreboardReading] = []
        for token in valid {
            let text = token.text as NSString
            for match in regex.matches(in: token.text, range: NSRange(location: 0, length: text.length)) {
                guard let left = Int(text.substring(with: match.range(at: 1))),
                      let right = Int(text.substring(with: match.range(at: 2))) else { continue }
                let prefix = text.substring(to: match.range.location)
                let suffix = text.substring(from: NSMaxRange(match.range))
                let inlineLabels = isLabel(prefix) && isLabel(suffix)
                guard inlineLabels || hasLabels(around: token, in: valid) || hasVerticalLabels(around: token, in: valid) else { continue }
                readings.append(ScoreboardReading(left: left, right: right, centerX: token.midX,
                                                  centerY: token.midY, confidence: token.confidence))
            }
        }
        // Vision may return each number as a separate text observation.
        let numbers = valid.filter { $0.text.range(of: #"^\s*[0-9]{1,3}\s*$"#, options: .regularExpression) != nil }
        for left in numbers {
            for right in numbers where right.x > left.x + left.width {
                guard abs(left.midY - right.midY) <= max(left.height, right.height) * 0.6,
                      let l = Int(left.text.trimmingCharacters(in: .whitespaces)),
                      let r = Int(right.text.trimmingCharacters(in: .whitespaces)) else { continue }
                let pair = Token(text: "", confidence: min(left.confidence, right.confidence), x: left.x,
                                 y: min(left.y, right.y), width: right.x + right.width - left.x,
                                 height: max(left.height, right.height))
                let horizontalPair = right.x - left.x - left.width < 0.12 && hasLabels(around: pair, in: valid)
                guard horizontalPair || hasVerticalLabels(around: pair, in: valid, split: (left, right)) else { continue }
                readings.append(ScoreboardReading(left: l, right: r, centerX: pair.midX,
                                                  centerY: pair.midY, confidence: pair.confidence))
            }
        }
        // Ambiguous multiple score strips are safer to ignore than to mix.
        let unique = readings.filter(\.isValid).reduce(into: [ScoreboardReading]()) { list, value in
            if !list.contains(where: { $0.sameScore(as: value) && $0.sameBoard(as: value) }) { list.append(value) }
        }
        return unique.count == 1 ? unique[0] : nil
    }

    private static func isLabel(_ text: String) -> Bool {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3
    }

    private static func hasLabels(around score: Token, in tokens: [Token]) -> Bool {
        let labels = tokens.filter {
            isLabel($0.text) && abs($0.midY - score.midY) < max($0.height, score.height) * 0.7
        }
        return labels.contains { $0.midX < score.x && score.x - ($0.x + $0.width) < 0.25 } &&
               labels.contains { $0.midX > score.x + score.width && $0.x - score.x - score.width < 0.25 }
    }
}

/// Debounce OCR before accepting a legal basketball scoring increment. Never
/// interpret the first score, a correction, or a return after a gap as a basket.
struct ScoreChangeFilter {
    struct Candidate {
        let time: TimeInterval
        let confidence: Double // Zero for OCR-only; never invent a model score.
        let isScoreboard: Bool
        var requiresReview: Bool = false
    }
    struct Event {
        let time: TimeInterval // Estimated play time; score graphics can update late.
        let observedTime: TimeInterval
        let left: Int
        let right: Int
    }
    struct Coverage {
        let start: TimeInterval
        var end: TimeInterval
    }
    private struct Pending {
        let reading: ScoreboardReading
        let firstTime: TimeInterval
        var lastTime: TimeInterval
        var count: Int
    }
    private var pending: Pending?
    private var baseline: ScoreboardReading?
    private var lastReadingTime: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private(set) var events: [Event] = []
    private(set) var coverage: [Coverage] = []

    mutating func append(time: TimeInterval, reading: ScoreboardReading?) {
        guard time.isFinite, time >= 0 else { return }
        if let previous = lastSampleTime, time <= previous { return }
        lastSampleTime = time
        if let last = lastReadingTime, time - last > 3 {
            baseline = nil
            pending = nil
            lastReadingTime = nil
        }
        guard let reading, reading.isValid else { return }
        if let baseline, !reading.sameBoard(as: baseline) {
            self.baseline = nil
            pending = nil
            lastReadingTime = nil
        }
        let continuesCoverage = lastReadingTime.map { time - $0 <= 3 } ?? false
        lastReadingTime = time
        if var p = pending, reading.sameScore(as: p.reading), reading.sameBoard(as: p.reading), time - p.lastTime <= 2.5 {
            p.count += 1
            p.lastTime = time
            pending = p
        } else {
            pending = Pending(reading: reading, firstTime: time, lastTime: time, count: 1)
        }
        guard let p = pending, p.count >= 3, time - p.firstTime >= 0.75 else { return }
        if continuesCoverage, baseline != nil, let last = coverage.last, time - last.end <= 3 {
            coverage[coverage.count - 1].end = time
        } else {
            coverage.append(Coverage(start: p.firstTime, end: time))
        }
        guard let old = baseline else { baseline = reading; return }
        guard !reading.sameScore(as: old) else { return }
        let leftDelta = reading.left - old.left
        let rightDelta = reading.right - old.right
        guard ((1...3).contains(leftDelta) && rightDelta == 0) ||
              ((1...3).contains(rightDelta) && leftDelta == 0) else {
            // A transient OCR decrease followed by recovery must not fabricate
            // a basket. Resynchronize only after a prolonged stable correction.
            if p.count >= 8, time - p.firstTime >= 6 {
                baseline = reading
                coverage.append(Coverage(start: time, end: time))
            }
            return
        }
        baseline = reading
        events.append(Event(time: max(0, p.firstTime - 2), observedTime: p.firstTime,
                            left: reading.left, right: reading.right))
    }

    /// Only reject a visual-only event if a continuous, stable score strip was
    /// readable before and well after it. Missing OCR must not veto model events.
    func coversVisualEvent(at time: TimeInterval) -> Bool {
        coverage.contains { $0.start <= time - 2 && $0.end >= time + 8 }
    }

    func candidates(visualEvents: [ShotEventFilter.Event]) -> [Candidate] {
        var used: Set<Int> = []
        var result: [Candidate] = []
        for event in events {
            let match = visualEvents.indices.filter {
                !used.contains($0) && abs(visualEvents[$0].time - event.time) <= 6
            }.min { abs(visualEvents[$0].time - event.time) < abs(visualEvents[$1].time - event.time) }
            if let match {
                used.insert(match)
                result.append(Candidate(time: visualEvents[match].time, confidence: visualEvents[match].confidence,
                                        isScoreboard: true))
            } else {
                result.append(Candidate(time: event.time, confidence: 0, isScoreboard: true))
            }
        }
        for (index, event) in visualEvents.enumerated() where !used.contains(index) {
            guard !events.contains(where: { abs($0.time - event.time) <= 6 }),
                  !coversVisualEvent(at: event.time) else { continue }
            result.append(Candidate(time: event.time, confidence: event.confidence, isScoreboard: false,
                                    requiresReview: event.requiresReview))
        }
        return result.sorted { $0.time < $1.time }
    }
}
