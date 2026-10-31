import Foundation

/// Temporal post-processing for the model's per-frame ball-in-basket scores.
/// These are candidate events, not proof that a basket was made.
struct ShotEventFilter {
    struct Sample {
        let time: TimeInterval
        let confidence: Double

        var isValid: Bool {
            time.isFinite && time >= 0 && confidence.isFinite && (0...1).contains(confidence)
        }
    }

    struct Event {
        let time: TimeInterval
        let confidence: Double
        let supportingFrames: Int
    }

    // Keep duplicate suppression much shorter than the exported clip's lead-in:
    // overlapping highlight clips can still contain two distinct baskets.
    static let duplicateWindow: TimeInterval = 1.5

    private let threshold: Double
    private let supportThreshold: Double
    private let minimumFrames: Int
    private let maximumSupportGap: TimeInterval
    private let confirmationWindow: TimeInterval
    private let minimumEvidenceSpan: TimeInterval
    private let maximumPresence: TimeInterval
    private var lastSampleTime: TimeInterval?
    private var run: Run?
    private var completedEvents: [Event] = []

    private struct Run {
        let firstTime: TimeInterval
        var lastTime: TimeInterval
        var peak: Sample
        var window: [Sample]
        var supportingFrames: Int
        var confirmed = false
        var prolonged = false
    }

    init(threshold: Double, frameRate: Double? = nil) {
        let normalized = threshold.isFinite ? min(0.95, max(0.05, threshold)) : 0.55
        self.threshold = normalized
        supportThreshold = max(0.05, normalized - 0.10)
        let fps: Double
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            fps = min(30, frameRate)
        } else {
            fps = 30
        }
        let interval = 1 / fps
        // The detector now requires a nearby rim. A distant ball can pass the
        // net in only two sampled frames; three is unnecessarily restrictive.
        let frames = 2
        minimumFrames = frames
        maximumSupportGap = max(0.12, 2.5 * interval)
        confirmationWindow = max(0.30, Double(frames - 1) * interval * 1.5)
        minimumEvidenceSpan = Double(frames - 1) * interval * 0.5
        maximumPresence = max(2.0, 4 * interval)
    }

    /// Append ordered samples, including low scores so gaps close a run promptly.
    /// Repeated timestamps never count as additional supporting frames.
    mutating func append(_ sample: Sample) {
        guard sample.isValid else { return }
        if let previous = lastSampleTime, sample.time <= previous { return }
        lastSampleTime = sample.time

        if let current = run, sample.time - current.lastTime > maximumSupportGap {
            completeRun()
        }
        guard sample.confidence >= supportThreshold else { return }

        guard var current = run else {
            run = Run(firstTime: sample.time, lastTime: sample.time, peak: sample,
                      window: [sample], supportingFrames: 1)
            return
        }
        current.lastTime = sample.time
        current.supportingFrames += 1
        if sample.confidence > current.peak.confidence { current.peak = sample }
        if sample.time - current.firstTime > maximumPresence {
            // A target that stays present continuously is not a brief scoring event.
            // Keep the run rejected until the target disappears; do not split it into goals.
            current.prolonged = true
            current.window.removeAll(keepingCapacity: true)
        } else if !current.prolonged {
            current.window.append(sample)
            current.window.removeAll { sample.time - $0.time > confirmationWindow }
            let strongFrames = current.window.filter { $0.confidence >= threshold }.count
            let span = sample.time - (current.window.first?.time ?? sample.time)
            if current.window.count >= minimumFrames, strongFrames >= 2, span >= minimumEvidenceSpan {
                current.confirmed = true
            }
        }
        run = current
    }

    /// The active run is provisional: the count can fall if it becomes prolonged.
    var candidateCount: Int { currentEvents.count }

    var currentEvents: [Event] {
        var proposals = completedEvents
        if let current = run, let event = event(from: current) { proposals.append(event) }
        return Self.suppressDuplicates(proposals)
    }

    mutating func finish() -> [Event] {
        completeRun()
        return Self.suppressDuplicates(completedEvents)
    }

    static func events(in samples: [Sample], threshold: Double, frameRate: Double? = nil) -> [Event] {
        var filter = ShotEventFilter(threshold: threshold, frameRate: frameRate)
        let ordered = samples.filter(\.isValid).sorted {
            $0.time == $1.time ? $0.confidence > $1.confidence : $0.time < $1.time
        }
        for sample in ordered { filter.append(sample) }
        return filter.finish()
    }

    private func event(from run: Run) -> Event? {
        guard run.confirmed, !run.prolonged, run.peak.confidence >= threshold else { return nil }
        return Event(time: run.peak.time, confidence: run.peak.confidence, supportingFrames: run.supportingFrames)
    }

    private mutating func completeRun() {
        if let current = run, let event = event(from: current) { completedEvents.append(event) }
        run = nil
    }

    private static func suppressDuplicates(_ proposals: [Event]) -> [Event] {
        let strongestFirst = proposals.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.supportingFrames != $1.supportingFrames { return $0.supportingFrames > $1.supportingFrames }
            return $0.time < $1.time
        }
        var kept: [Event] = []
        for event in strongestFirst {
            if kept.allSatisfy({ abs($0.time - event.time) >= duplicateWindow }) { kept.append(event) }
        }
        return kept.sorted { $0.time < $1.time }
    }
}
