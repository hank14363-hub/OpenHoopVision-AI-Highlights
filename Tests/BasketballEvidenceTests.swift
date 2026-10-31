import Foundation

@main
struct BasketballEvidenceTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("Evidence check failed: \(message)") }
    }
    private static func reading(_ left: Int, _ right: Int = 0, x: Double = 0.5) -> ScoreboardReading {
        ScoreboardReading(left: left, right: right, centerX: x, centerY: 0.5, confidence: 0.95)
    }
    private static func stable(_ filter: inout ScoreChangeFilter, _ time: Double, _ left: Int, _ right: Int = 0) {
        for offset in [0.0, 0.5, 1.0] { filter.append(time: time + offset, reading: reading(left, right)) }
    }
    private static func token(_ text: String, x: Double, width: Double = 0.10, y: Double = 0.4, confidence: Double = 0.95) -> ScoreboardParser.Token {
        .init(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.15)
    }
    private static func scoreTokens(_ text: String) -> [ScoreboardParser.Token] {
        [token("Home Team", x: 0.1, width: 0.23), token(text, x: 0.44), token("Away Team", x: 0.65, width: 0.23)]
    }
    private static func object(_ classID: Int, _ confidence: Double, _ x: Double, _ y: Double, _ w: Double = 20, _ h: Double = 10) -> BasketballObject {
        BasketballObject(classID: classID, confidence: confidence, x1: x, y1: y, x2: x + w, y2: y + h)
    }

    static func main() {
        let rim = object(1, 0.8, 200, 100, 30, 10)
        let goal = object(2, 0.9, 207, 105, 15, 18)
        expect(BasketSpatialGate.confidence(in: [rim, goal]) == 0.9, "target beside rim retained")
        expect(BasketSpatialGate.confidence(in: [goal]) == 0, "class 2 without rim rejected")
        expect(BasketSpatialGate.confidence(in: [rim, object(2, 0.99, 600, 300)]) == 0, "unrelated court region rejected")
        expect(BasketSpatialGate.confidence(in: [rim, object(2, 0.99, 200, 300)]) == 0, "ball at player's waist is not in rim")
        expect(BasketSpatialGate.confidence(in: [rim, object(2, 0.99, 100, 70, 230, 200)]) == 0, "giant box rejected")
        expect(BasketSpatialGate.confidence(in: [rim, object(0, 0.99, 207, 105)]) == 0, "ordinary ball is not class-2 evidence")
        expect(BasketSpatialGate.confidence(in: [rim, object(2, .nan, 207, 105)]) == 0, "invalid score rejected")
        expect(BasketSpatialGate.confidence(in: [rim, goal, object(2, 0.99, 700, 300)]) == 0.9, "spurious higher score does not win")

        for text in ["0 -0", "2 -0", "6 - 0", "13- 1", "17- 7", "15 – 3", "15 · 5"] {
            expect(ScoreboardParser.reading(from: scoreTokens(text)) != nil, "score OCR format: \(text)")
        }
        expect(ScoreboardParser.reading(from: scoreTokens("4:58")) == nil, "clock is not a score")
        expect(ScoreboardParser.reading(from: [token("13-1", x: 0.4)]) == nil, "unlabelled numbers ignored")
        expect(ScoreboardParser.reading(from: scoreTokens("Home 13-1 Away"))?.left == 13, "combined line supported")
        let split = [token("Home", x: 0.1, width: 0.2), token("13", x: 0.43, width: 0.04),
                     token("1", x: 0.51, width: 0.03), token("Away", x: 0.65, width: 0.2)]
        expect(ScoreboardParser.reading(from: split)?.right == 1, "separate numeric observations supported")
        expect(ScoreboardParser.reading(from: scoreTokens("999-0")) == nil, "out-of-range score ignored")
        expect(ScoreboardParser.reading(from: [token("Home", x: 0.1), token("2-0", x: 0.4, confidence: 0.2), token("Away", x: 0.65)]) == nil, "low confidence OCR ignored")
        expect(ScoreboardParser.reading(from: scoreTokens("2-0") + [token("4-1", x: 0.45)]) == nil, "conflicting strips rejected")
        let vertical = [token("HOME", x: 0.35, width: 0.10, y: 0.20),
                        token("GUEST", x: 0.70, width: 0.12, y: 0.20),
                        token("2", x: 0.43, width: 0.04, y: 0.55),
                        token("1", x: 0.56, width: 0.04, y: 0.55)]
        expect(ScoreboardParser.reading(from: vertical)?.left == 2, "vertical HOME/GUEST labels supported")
        expect(ScoreboardParser.reading(from: vertical)?.right == 1, "vertical score pair supported")
        let clock = [token("HOME", x: 0.35, width: 0.10, y: 0.20),
                     token("GUEST", x: 0.70, width: 0.12, y: 0.20),
                     token("5:25", x: 0.43, width: 0.14, y: 0.55)]
        expect(ScoreboardParser.reading(from: clock) == nil, "vertical game clock is not a score")

        var filter = ScoreChangeFilter()
        stable(&filter, 0, 0)
        expect(filter.events.isEmpty, "initial scoreboard does not count")
        filter.append(time: 2, reading: reading(2))
        filter.append(time: 2.5, reading: reading(0))
        expect(filter.events.isEmpty, "single OCR spike does not count")
        stable(&filter, 3, 2)
        expect(filter.events.count == 1 && filter.events[0].observedTime == 3, "stable two point increase counts once")
        expect(filter.events[0].time == 1, "estimate precedes delayed score update")
        stable(&filter, 4.5, 2)
        expect(filter.events.count == 1, "unchanged score not duplicated")
        stable(&filter, 6, 5)
        expect(filter.events.count == 2, "three point increase accepted")
        stable(&filter, 8, 5, 1)
        expect(filter.events.count == 3, "opposing free throw accepted")
        stable(&filter, 10, 3, 1)
        stable(&filter, 12, 5, 1)
        expect(filter.events.count == 3, "OCR decrease/recovery does not fabricate points")
        stable(&filter, 14, 12, 1)
        expect(filter.events.count == 3, "large jump not treated as single goal")
        var gap = ScoreChangeFilter()
        stable(&gap, 0, 0)
        gap.append(time: 5, reading: nil)
        stable(&gap, 6, 2)
        expect(gap.events.isEmpty, "return after missing graphic establishes new baseline")
        var location = ScoreChangeFilter()
        stable(&location, 0, 0)
        for t in [2.0, 2.5, 3] { location.append(time: t, reading: reading(2, x: 0.8)) }
        expect(location.events.isEmpty, "different board establishes baseline")
        var duplicated = ScoreChangeFilter()
        for _ in 0..<20 { duplicated.append(time: 1, reading: reading(0)) }
        stable(&duplicated, 2, 2)
        expect(duplicated.events.isEmpty, "duplicate timestamp cannot confirm baseline")
        var invalid = ScoreChangeFilter()
        invalid.append(time: .nan, reading: reading(0))
        invalid.append(time: 0, reading: reading(-1))
        stable(&invalid, 1, 2)
        expect(invalid.events.isEmpty, "invalid input does not supply evidence")

        let visual = ShotEventFilter.Event(time: 0.8, confidence: 0.8, supportingFrames: 2)
        let fused = filter.candidates(visualEvents: [visual])
        expect(fused.count == 3, "score and visual evidence for same basket merge")
        expect(fused[0].time == 0.8 && fused[0].confidence == 0.8 && fused[0].isScoreboard, "use visual timing without inventing confidence")
        expect(fused[1].confidence == 0, "OCR-only candidate has no fabricated model probability")
        var covered = ScoreChangeFilter()
        for i in 0...40 { covered.append(time: Double(i) * 0.5, reading: reading(0)) }
        let falseVisual = ShotEventFilter.Event(time: 5, confidence: 0.99, supportingFrames: 5)
        expect(covered.candidates(visualEvents: [falseVisual]).isEmpty, "stable unchanged score vetoes visual false positive")
        expect(ScoreChangeFilter().candidates(visualEvents: [falseVisual]).count == 1, "absent scoreboard does not veto visual candidates")
        expect(covered.candidates(visualEvents: [.init(time: 19, confidence: 0.9, supportingFrames: 3)]).count == 1, "insufficient following coverage cannot veto")
        print("Passed \(checks) spatial and scoreboard evidence checks.")
    }
}
