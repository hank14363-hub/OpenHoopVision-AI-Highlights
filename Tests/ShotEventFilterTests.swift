import Foundation

@main
struct ShotEventFilterTests {
    typealias Sample = ShotEventFilter.Sample
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fatalError("Temporal filter check failed: \(message)")
        }
    }

    private static func burst(_ start: Double, peak: Double = 0.85) -> [Sample] {
        [Sample(time: start, confidence: peak - 0.05),
         Sample(time: start + 1 / 30, confidence: peak),
         Sample(time: start + 2 / 30, confidence: peak - 0.05)]
    }

    private static func events(_ samples: [Sample], threshold: Double = 0.55, fps: Double? = 30) -> [ShotEventFilter.Event] {
        ShotEventFilter.events(in: samples, threshold: threshold, frameRate: fps)
    }

    static func main() {
        expect(events([]).isEmpty, "empty input")
        expect(events([Sample(time: 1, confidence: 0.99)]).isEmpty, "a single high score must not count")
        expect(events(Array(burst(1).prefix(2))).isEmpty, "two frames at 30 FPS are insufficient")
        expect(events(burst(1)).count == 1, "a short, repeatedly confirmed event is retained")
        expect(abs((events(burst(1)).first?.time ?? 0) - (1 + 1 / 30)) < 0.000001, "use the peak frame's time")
        expect(events(burst(1, peak: 0.40)).isEmpty, "scores below threshold are rejected")
        expect(events(burst(1, peak: 0.65), threshold: 0.75).isEmpty, "raising the threshold rejects a weaker burst")

        let weakNeighbors = [Sample(time: 1, confidence: 0.50), Sample(time: 1.04, confidence: 0.99), Sample(time: 1.08, confidence: 0.50)]
        expect(events(weakNeighbors).isEmpty, "one high spike plus weak neighbors is insufficient")
        expect(events(weakNeighbors, threshold: 0.45).count == 1, "the user's threshold still affects filtering")
        expect(events([Sample(time: 1, confidence: 0.9), Sample(time: 1.2, confidence: 0.9), Sample(time: 1.4, confidence: 0.9)]).isEmpty, "sparse unrelated spikes must not be combined")

        let duplicate = events(burst(1, peak: 0.75) + burst(1.6, peak: 0.90))
        expect(duplicate.count == 1 && duplicate[0].confidence == 0.90, "retain the stronger nearby event")
        expect(events(burst(1) + burst(3)).count == 2, "two baskets remain distinct even when exported clips overlap")
        expect(events(burst(1) + burst(2.6)).count == 2, "events outside the duplicate window stay separate")
        expect(events(burst(1, peak: 0.80) + burst(1.6, peak: 0.80)).first?.time == events(burst(1, peak: 0.80)).first?.time, "equal scores break ties deterministically")

        let sustained = (0..<100).map { Sample(time: 1 + Double($0) / 30, confidence: 0.90) }
        expect(events(sustained).isEmpty, "persistent detections do not become a scoring event")
        expect(events(sustained + burst(6)).count == 1, "a real event can follow a rejected persistent detection")
        expect(events(Array(repeating: Sample(time: 1, confidence: 0.99), count: 50)).isEmpty, "duplicate timestamps cannot supply confirmation")
        expect(events(Array((burst(3) + burst(1)).reversed())).map(\.time) == events(burst(1) + burst(3)).map(\.time), "batch input is sorted before filtering")

        let invalid = [Sample(time: .nan, confidence: 0.99), Sample(time: .infinity, confidence: 0.99),
                       Sample(time: -1, confidence: 0.99), Sample(time: 0, confidence: .nan),
                       Sample(time: 0, confidence: -1), Sample(time: 0, confidence: 1.1)]
        expect(events(invalid).isEmpty, "invalid scores and timestamps are ignored")
        expect(events(invalid + burst(1)).count == 1, "invalid input does not poison later valid events")
        expect(events([Sample(time: 1, confidence: 0.85), Sample(time: 1.2, confidence: 0.90)], fps: 5).count == 1, "low-frame-rate evidence is handled separately")
        expect(events(burst(1), fps: 120).count == 1, "high-frame-rate input follows the app's 30 FPS sampling cap")
        expect(events(burst(1), fps: nil).count == 1, "missing frame-rate metadata has a safe default")
        expect(events(burst(1), threshold: .nan).count == 1, "invalid thresholds have a safe default")

        var streaming = ShotEventFilter(threshold: 0.55, frameRate: 30)
        for sample in sustained.prefix(3) { streaming.append(sample) }
        expect(streaming.candidateCount == 1, "an active confirmed event is provisional")
        for sample in sustained.dropFirst(3) { streaming.append(sample) }
        expect(streaming.candidateCount == 0 && streaming.finish().isEmpty, "a provisional event is withdrawn if it becomes persistent")

        let allSamples = burst(1) + burst(3, peak: 0.90)
        var resumed = ShotEventFilter(threshold: 0.55, frameRate: 30)
        // Replaying a checkpoint and then appending new frames is the resume path.
        for sample in allSamples.prefix(2) { resumed.append(sample) }
        for sample in allSamples.dropFirst(2) { resumed.append(sample) }
        let resumedEvents = resumed.finish()
        expect(resumedEvents.map(\.time) == events(allSamples).map(\.time), "resume boundaries do not duplicate or lose an event")
        expect(resumed.finish().map(\.time) == resumedEvents.map(\.time), "finishing twice is idempotent")
        print("Passed \(checks) temporal filter checks.")
    }
}
