import Foundation

@main
struct BasketMotionTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("Motion check failed: \(message)") }
    }
    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    private static func box(_ cls: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ score: Double = 0.9) -> BasketballObject {
        .init(classID: cls, confidence: score, x1: x, y1: y, x2: x + w, y2: y + h)
    }
    private static func scene(_ y: Double, x: Double = 0, cls: Int = 2, shift: Double = 0, aspect: Double = 1) -> [BasketballObject] {
        let rim = box(1, 0.45 + shift, 0.40 / aspect, 0.10, 0.02 / aspect)
        let ball = box(cls, 0.49 + shift + x * 0.10, (0.40 + y * 0.10) / aspect, 0.02, 0.02 / aspect)
        return [rim, ball]
    }
    private static func events(_ ys: [Double], xs: [Double]? = nil, classes: [Int]? = nil,
                               times: [Double]? = nil, shifts: [Double]? = nil, aspect: Double = 1) -> [ShotEventFilter.Event] {
        var filter = BasketMotionFilter(threshold: 0.55, frameRate: 30, imageAspectRatio: aspect)
        for i in ys.indices {
            filter.append(time: times?[i] ?? Double(i) / 30,
                          objects: scene(ys[i], x: xs?[i] ?? 0, cls: classes?[i] ?? 2,
                                         shift: shifts?[i] ?? 0, aspect: aspect))
        }
        return filter.finish()
    }

    static func main() {
        // Model-pixel boxes for known source rectangles; these catch the square
        // crop's 272-pixel horizontal padding and landscape's 8-pixel y padding.
        let landscape = BasketImageGeometry.imageObject(box(0, 128, 80, 128, 72), imageWidth: 1280, imageHeight: 720)!
        expect(near(landscape.x1, 0.1) && near(landscape.y1, 0.1), "landscape centered padding removed")
        expect(near(landscape.width, 0.1) && near(landscape.height, 0.1), "landscape dimensions retained")
        let square = BasketImageGeometry.imageObject(box(0, 345.6, 147.2, 147.2, 147.2), imageWidth: 400, imageHeight: 400)!
        expect(near(square.x1, 0.1) && near(square.y1, 0.2), "square crop padding removed")
        let crop = ImageRegion(x: 0.3, y: 0.2, width: 0.2, height: 0.4)
        let mapped = BasketImageGeometry.imageObject(box(0, 345.6, 147.2, 147.2, 147.2), imageWidth: 400, imageHeight: 400, region: crop)!
        expect(near(mapped.x1, 0.32) && near(mapped.y1, 0.28), "crop maps back into source")
        expect(near(mapped.width, 0.04) && near(mapped.height, 0.08), "crop dimensions map to source")
        let portrait = BasketImageGeometry.imageObject(box(1, 474.4, 73.6, 41.4, 73.6), imageWidth: 720, imageHeight: 1280)!
        expect(near(portrait.x1, 0.1) && near(portrait.y1, 0.1), "portrait padding removed")
        expect(BasketImageGeometry.imageObject(box(2, 0, 0, 40, 40), imageWidth: 400, imageHeight: 400) == nil, "padding-only detection rejected")
        expect(BasketImageGeometry.imageObject(box(0, 270, 0, 40, 40), imageWidth: 400, imageHeight: 400)?.x1 == 0, "edge detection clipped")
        expect(BasketImageGeometry.imageObject(box(0, 0, 0, 20, 20), imageWidth: 0, imageHeight: 720) == nil, "zero image width rejected")
        let edge = BasketImageGeometry.crop(around: box(1, 0, 0, 0.02, 0.01), imageWidth: 1280, imageHeight: 720)!
        expect(edge.x == 0 && edge.y == 0 && edge.width > 0 && edge.height > 0, "edge ROI clipped to image")
        expect(BasketImageGeometry.crop(around: box(1, 0.4, 0.4, 0.2, 0.05), imageWidth: 1280, imageHeight: 720) == nil, "large rim avoids crop retry")
        let a = box(0, 0.2, 0.2, 0.1, 0.1)
        expect(BasketImageGeometry.deduplicated([a, a, box(1, 0.2, 0.2, 0.1, 0.1)]).count == 2, "full/crop same-class duplicates removed")
        let encoded = try! JSONEncoder().encode([a])
        expect(try! JSONDecoder().decode([BasketballObject].self, from: encoded).first?.x1 == a.x1, "object evidence persists for resume")

        let descent = events([-0.6, 0, 0.6], classes: [0, 2, 0])
        expect(descent.count == 1 && !descent[0].requiresReview, "ordered downward passage corroborates target")
        expect(near(descent[0].time, 1.0 / 30), "event anchored at rim passage")
        let appearance = events([0, 0])
        expect(appearance.isEmpty, "two target frames without ball passage are discarded")
        let stationary = events(Array(repeating: 0, count: 12))
        expect(stationary.count == 1 && stationary[0].requiresReview, "brief strong target pulse can be reviewed without ordinary ball detections")
        let prolonged = events(Array(repeating: 0, count: 90))
        expect(prolonged.isEmpty, "persistent target discarded")
        let upward = events([0.6, 0, -0.6])
        expect(upward.isEmpty, "upward motion is discarded")
        let absentAbove = events([0, 0.3, 0.6])
        expect(absentAbove.isEmpty, "below-only fall is discarded")
        let side = events([-0.6, 0, 0.6], xs: [0.8, 0.8, 0.8])
        expect(side.isEmpty, "descent outside rim is discarded")
        let jump = events([-0.6, 0, 0.6], xs: [-0.8, 0, 0.65])
        expect(jump.isEmpty, "unrelated lateral ball jump rejected")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 0]).first?.requiresReview == false, "single target frame recovers brief passage")
        expect(events([-0.6, 0, 0.6], classes: [0, 0, 0]).isEmpty, "ball-only passage does not enter review list")
        expect(events([-0.6, 0, 0.6], times: [0, 0.3, 0.6]).isEmpty, "long gaps cannot connect a trajectory")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 0], shifts: [0, 0.3, 0.3]).allSatisfy({ $0.requiresReview }), "cut to another rim cannot fabricate a complete passage")
        expect(events([-0.6, 0, 0.6], times: [0, 0, 0]).isEmpty, "repeated timestamp is not a trajectory")
        let pan = events([-0.6, 0, 0.6], classes: [0, 2, 0], shifts: [0, 0.01, 0.02])
        expect(pan.count == 1 && !pan[0].requiresReview, "small camera pan uses rim-relative coordinates")
        let wide = events([-0.6, 0, 0.6], classes: [0, 2, 0], aspect: 720.0 / 1280)
        expect(wide.count == 1 && !wide[0].requiresReview && near(wide[0].time, descent[0].time), "landscape aspect ratio preserves physical passage")

        var continuous = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        var restored = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        let values = [-0.6, 0, 0.6, 0.9]
        for i in values.indices { continuous.append(time: Double(i) / 30, objects: scene(values[i], cls: i == 1 ? 2 : 0)) }
        // Resume reconstructs the filter from persisted hits, including before
        // the checkpoint boundary, rather than losing the start of a passage.
        let hits = values.enumerated().map { (Double($0.offset) / 30, scene($0.element, cls: $0.offset == 1 ? 2 : 0)) }
        for hit in hits.prefix(2) { restored.append(time: hit.0, objects: hit.1) }
        for hit in hits.dropFirst(2) { restored.append(time: hit.0, objects: hit.1) }
        let finished = continuous.finish()
        let resumed = restored.finish()
        expect(finished.count == resumed.count && finished.first?.time == resumed.first?.time && finished.first?.requiresReview == resumed.first?.requiresReview, "checkpoint reconstruction matches uninterrupted scan")
        expect(continuous.finish().count == finished.count, "finish idempotent")
        var noScore = ScoreChangeFilter()
        let weak = noScore.candidates(visualEvents: appearance)
        expect(weak.isEmpty, "absence of scoreboard does not resurrect rejected appearances")
        for t in [0.0, 0.5, 1.0] {
            noScore.append(time: t, reading: .init(left: 0, right: 0, centerX: 0.5, centerY: 0.5, confidence: 0.95))
        }
        for t in [2.0, 2.5, 3.0] {
            noScore.append(time: t, reading: .init(left: 2, right: 0, centerX: 0.5, centerY: 0.5, confidence: 0.95))
        }
        expect(noScore.candidates(visualEvents: appearance).first?.isScoreboard == true, "stable score increase still generates scoreboard candidate")
        expect(events([-0.6, 0, 0.6]).isEmpty, "moving class-2 boxes alone cannot fake a basketball trajectory")
        expect(events([-0.6, 0, 0.6], classes: [2, 2, 0]).first?.requiresReview == true, "missing ordinary ball above can recover for review")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 2]).first?.requiresReview == true, "missing ordinary ball below can recover for review")
        expect(events([0.6, 0, -0.6], classes: [0, 2, 0]).isEmpty, "real-ball upward bounce rejected")
        expect(events([-0.6, 0, 0.6], xs: [0.8, 0.8, 0.8], classes: [0, 2, 0]).isEmpty, "off-rim real-ball descent rejected")
        expect(events([-0.6, 0, 0.6], xs: [-0.8, 0, 0.65], classes: [0, 2, 0]).isEmpty, "cross-ball lateral jump rejected")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 0], times: [0, 0.3, 0.6]).isEmpty, "long gap breaks class sequence")
        var lowTarget = BasketMotionFilter(threshold: 0.95)
        for i in 0..<3 { lowTarget.append(time: Double(i) / 30, objects: scene([-0.6, 0, 0.6][i], cls: i == 1 ? 2 : 0)) }
        expect(lowTarget.finish().isEmpty, "target confidence must meet user threshold")
        var skinny = BasketMotionFilter(threshold: 0.55)
        for i in 0..<3 {
            let objects = scene([-0.6, 0, 0.6][i], cls: i == 1 ? 2 : 0).map { item in
                item.classID == 0 ? box(0, item.midX - 0.001, item.y1, 0.002, item.height) : item
            }
            skinny.append(time: Double(i) / 30, objects: objects)
        }
        expect(skinny.finish().isEmpty, "tiny elongated specks cannot bracket a goal")
        var unrelatedTarget = BasketMotionFilter(threshold: 0.55)
        for i in 0..<3 { unrelatedTarget.append(time: Double(i) / 30, objects: scene([-0.6, 0, 0.6][i], x: i == 1 ? 0.7 : 0, cls: i == 1 ? 2 : 0)) }
        expect(unrelatedTarget.finish().isEmpty, "target away from interpolated ball path rejected")

        // Reproduce the review-list flood with repeated intermittent appearances.
        // This is a controlled detection fixture, not a real-video accuracy score.
        var oldAppearance = ShotEventFilter(threshold: 0.55, frameRate: 30)
        var strict = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        for burst in 0..<134 {
            for sample in 0..<4 {
                let time = Double(burst) * 3 + Double(sample) / 30
                let objects = sample < 2 ? scene(0) : []
                strict.append(time: time, objects: objects)
                oldAppearance.append(.init(time: time, confidence: sample < 2 ? 0.9 : 0))
            }
        }
        expect(oldAppearance.finish().count == 134, "fixture reproduces 134 appearance events admitted by old fallback")
        expect(strict.finish().isEmpty, "134 appearance-only bursts produce zero new candidates")
        for i in 0..<3 { strict.append(time: 500 + Double(i) / 30, objects: scene([-0.6, 0, 0.6][i], cls: i == 1 ? 2 : 0)) }
        let mixed = strict.finish()
        expect(mixed.count == 1 && mixed[0].time > 500, "real passage survives after many rejected bursts")
        var multiple = BasketMotionFilter(threshold: 0.55)
        for base in [0.0, 2.0] {
            for i in 0..<3 { multiple.append(time: base + Double(i) / 30, objects: scene([-0.6, 0, 0.6][i], cls: i == 1 ? 2 : 0)) }
        }
        expect(multiple.currentEvents.count == 2 && multiple.finish().count == 2, "live and final preserve separate supported baskets")
        let approach = events([-0.6, 0], classes: [0, 2])
        expect(approach.count == 1 && approach[0].requiresReview, "approach-only evidence recovers candidate without requiring exit frame")
        let exit = events([0, 0.6], classes: [2, 0])
        expect(exit.count == 1 && exit[0].requiresReview, "exit-only evidence recovers candidate without requiring approach frame")
        let classChanges = events([-0.6, -0.2, 0.2, 0.6])
        expect(classChanges.count == 1 && classChanges[0].requiresReview, "four-frame class-2 pulse survives missing ordinary class labels")
        var rimDropout = BasketMotionFilter(threshold: 0.55)
        for i in 0..<5 {
            let objects: [BasketballObject]
            if i % 2 == 1 { objects = [] }
            else { objects = scene([-0.6, 0, 0.6][i / 2], cls: i == 2 ? 2 : 0) }
            rimDropout.append(time: Double(i) / 30, objects: objects)
        }
        expect(rimDropout.finish().count == 1 && rimDropout.finish()[0].requiresReview == false, "brief rim dropouts preserve full trajectory")
        expect(continuous.evidenceCounts["fullMotion"] == 1, "evidence summary reports full motion")
        var pulseFilter = BasketMotionFilter(threshold: 0.55)
        for i in 0..<4 { pulseFilter.append(time: Double(i) / 30, objects: scene(0)) }
        expect(pulseFilter.finish().count == 1 && pulseFilter.evidenceCounts["strongAppearance"] == 1, "finalization retains and labels strong appearance recovery")
        expect(pulseFilter.finish().count == 1, "pulse finish idempotent")
        var sparsePulse = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        for i in 0..<4 { sparsePulse.append(time: Double(i) * 0.29, objects: scene(0)) }
        expect(sparsePulse.finish().isEmpty, "sparse intermittent hits cannot masquerade as a continuous pulse")
        var flicker = BasketMotionFilter(threshold: 0.55)
        for i in 0..<120 { flicker.append(time: Double(i) / 30, objects: i % 9 < 4 ? scene(0) : []) }
        expect(flicker.finish().isEmpty, "repeated short gaps in persistent background do not split into goals")
        var lowPeak = BasketMotionFilter(threshold: 0.55)
        for i in 0..<6 {
            let values = scene(0).map { item in box(item.classID, item.x1, item.y1, item.width, item.height, 0.60) }
            lowPeak.append(time: Double(i) / 30, objects: values)
        }
        expect(lowPeak.finish().isEmpty, "appearance recovery requires a strong peak instead of merely meeting threshold")
        var moderatePulse = BasketMotionFilter(threshold: 0.55)
        for (index, score) in [0.70, 0.67, 0.66, 0.68].enumerated() {
            let objects = scene(0).map { box($0.classID, $0.x1, $0.y1, $0.width, $0.height, score) }
            moderatePulse.append(time: Double(index) / 30, objects: objects)
        }
        expect(moderatePulse.finish().count == 1 && moderatePulse.finish()[0].requiresReview, "moderately strong pulse recovers without an arbitrary 75 percent floor")
        var diag = BasketAnalysisDiagnostics()
        diag.append(time: 0, objects: scene(0), threshold: 0.55, imageAspectRatio: 1)
        diag.append(time: 0.1, objects: scene(-0.6, cls: 0), threshold: 0.55, imageAspectRatio: 1)
        diag.append(time: 10, objects: [], threshold: 0.55, imageAspectRatio: 1)
        expect(diag.processedFrames == 3 && diag.framesWithBall == 1 && diag.framesWithRim == 2, "diagnostics count actual model object coverage")
        expect(diag.framesWithTarget == 1 && diag.framesAtThreshold == 1, "diagnostics distinguish target presence and usable confidence")
        expect(diag.sampleFrames.count == 2 && diag.sampleFrames[0].targetConfidence == 0.9, "diagnostics retain representative high-target frame per ten seconds")
        expect(diag.targetConfidenceHistogram.reduce(0, +) == 3, "confidence histogram accounts for all frames including no target")
        diag.evidenceCounts = pulseFilter.evidenceCounts
        let diagnosticData = try! JSONEncoder().encode(diag)
        let decodedDiagnostics = try! JSONDecoder().decode(BasketAnalysisDiagnostics.self, from: diagnosticData)
        expect(decodedDiagnostics.evidenceCounts["strongAppearance"] == 1 && decodedDiagnostics.sampleFrames[0].objects.count == 2, "diagnostic JSON preserves evidence and boxes")
        print("Passed \(checks) motion and coordinate checks.")
    }
}
