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

        let descent = events([-0.6, 0, 0.6])
        expect(descent.count == 1 && !descent[0].requiresReview, "ordered downward passage corroborates target")
        expect(near(descent[0].time, 1.0 / 30), "event anchored at rim passage")
        let appearance = events([0, 0])
        expect(appearance.count == 1 && appearance[0].requiresReview, "two target frames alone require review")
        let stationary = events(Array(repeating: 0, count: 12))
        expect(stationary.count == 1 && stationary[0].requiresReview, "stationary target never confirms passage")
        let prolonged = events(Array(repeating: 0, count: 90))
        expect(prolonged.isEmpty, "persistent target discarded")
        let upward = events([0.6, 0, -0.6])
        expect(upward.count == 1 && upward[0].requiresReview, "upward motion cannot confirm basket")
        let absentAbove = events([0, 0.3, 0.6])
        expect(absentAbove.count == 1 && absentAbove[0].requiresReview, "below-only fall cannot confirm basket")
        let side = events([-0.6, 0, 0.6], xs: [0.8, 0.8, 0.8])
        expect(side.count == 1 && side[0].requiresReview, "descent outside rim is unconfirmed")
        let jump = events([-0.6, 0, 0.6], xs: [-0.8, 0, 0.65])
        expect(jump.count == 1 && jump[0].requiresReview, "unrelated lateral ball jump rejected")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 0]).first?.requiresReview == false, "single target frame recovers brief passage")
        expect(events([-0.6, 0, 0.6], classes: [0, 0, 0]).first?.requiresReview == true, "ordinary ball passage kept for review")
        expect(events([-0.6, 0, 0.6], times: [0, 0.3, 0.6]).isEmpty, "long gaps cannot connect a trajectory")
        expect(events([-0.6, 0, 0.6], classes: [0, 2, 0], shifts: [0, 0.3, 0.3]).isEmpty, "cut to another rim breaks passage")
        expect(events([-0.6, 0, 0.6], times: [0, 0, 0]).isEmpty, "repeated timestamp is not a trajectory")
        let pan = events([-0.6, 0, 0.6], shifts: [0, 0.01, 0.02])
        expect(pan.count == 1 && !pan[0].requiresReview, "small camera pan uses rim-relative coordinates")
        let wide = events([-0.6, 0, 0.6], aspect: 720.0 / 1280)
        expect(wide.count == 1 && !wide[0].requiresReview && near(wide[0].time, descent[0].time), "landscape aspect ratio preserves physical passage")

        var continuous = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        var restored = BasketMotionFilter(threshold: 0.55, frameRate: 30)
        let values = [-0.6, 0, 0.6, 0.9]
        for i in values.indices { continuous.append(time: Double(i) / 30, objects: scene(values[i])) }
        // Resume reconstructs the filter from persisted hits, including before
        // the checkpoint boundary, rather than losing the start of a passage.
        let hits = values.enumerated().map { (Double($0.offset) / 30, scene($0.element)) }
        for hit in hits.prefix(2) { restored.append(time: hit.0, objects: hit.1) }
        for hit in hits.dropFirst(2) { restored.append(time: hit.0, objects: hit.1) }
        let finished = continuous.finish()
        let resumed = restored.finish()
        expect(finished.count == resumed.count && finished.first?.time == resumed.first?.time && finished.first?.requiresReview == resumed.first?.requiresReview, "checkpoint reconstruction matches uninterrupted scan")
        expect(continuous.finish().count == finished.count, "finish idempotent")
        var noScore = ScoreChangeFilter()
        let weak = noScore.candidates(visualEvents: appearance)
        expect(weak.count == 1 && weak[0].requiresReview, "absence of scoreboard preserves review status")
        for t in [0.0, 0.5, 1.0] {
            noScore.append(time: t, reading: .init(left: 0, right: 0, centerX: 0.5, centerY: 0.5, confidence: 0.95))
        }
        for t in [2.0, 2.5, 3.0] {
            noScore.append(time: t, reading: .init(left: 2, right: 0, centerX: 0.5, centerY: 0.5, confidence: 0.95))
        }
        expect(noScore.candidates(visualEvents: appearance).first?.requiresReview == false, "stable score increase corroborates uncertain visual candidate")
        print("Passed \(checks) motion and coordinate checks.")
    }
}
