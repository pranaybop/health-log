import XCTest
@testable import LogCore

/// Trends calculations against the web app's own functions on the same made-up fixture and clock
/// (expected values came from running ios-app/www's functions on Fixtures/demo.json at
/// Nov 24 2026, 11:20 PM CT).
final class TrendsTests: XCTestCase {
    typealias T = Analytics.Trends
    static var dashboard: Dashboard = {
        let url = Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures")!
        return try! Dashboard.decode(Data(contentsOf: url))
    }()
    let now = LogTime.parse("2026-11-24T23:20:00-06:00")!
    var d: Dashboard { Self.dashboard }

    func testMaintenance() {
        let m = T.maintenance(d, now: now)
        XCTAssertEqual(m.burn.count, 27)
        XCTAssertEqual(m.logged.count, 21)
        XCTAssertEqual(m.weighIns, 23)
        XCTAssertEqual(m.watch ?? 0, 2833, accuracy: 1e-9)
        XCTAssertEqual(m.intake ?? 0, 2081.7619047619046, accuracy: 1e-6)
        XCTAssertEqual(m.rate ?? 0, -1.3414419850699701, accuracy: 1e-6)
        XCTAssertEqual(m.fromLogs ?? 0, 2752.48289729689, accuracy: 1e-4)
    }

    func testStallCheck() {
        let s = T.stallCheck(d, now: now)
        XCTAssertTrue(s.ready)
        XCTAssertEqual(s.summary, "No stall — weight moved -7.8 lb over the last 3 weeks (-3.0 lb/week).")
        XCTAssertEqual(s.changed, [
            "2.0 mg tirzepatide on Nov 8; 2.0 mg tirzepatide on Nov 15; 3.0 mg tirzepatide on Nov 22",
            "15 food days logged, averaging 2,037 calories.",
            "Dose feel logged on 19 days.",
        ])
    }

    func testWeightPaceAndProjection() {
        let sm = Analytics.smoothWeights(d)
        XCTAssertEqual(T.recentPace(sm, days: 28)?.weekly ?? 0, -2.817939543419389, accuracy: 1e-6)
        XCTAssertEqual(T.recentPace(sm, days: 28)?.n, 23)
        XCTAssertEqual(T.weightProjection(sm)?.weekly ?? 0, -2.9673597206806246, accuracy: 1e-6)
        XCTAssertEqual(Analytics.trendRate(sm, days: 28) ?? 0, -1.4504321324328018, accuracy: 1e-6)
        XCTAssertEqual(T.firstGlp1At(d), LogTime.parse("2026-11-02T16:00:00Z"))
        XCTAssertEqual(T.trainingBlockAt(d), LogTime.noon("2026-09-15"))
    }

    func testCyclesAndWearOff() {
        let c = T.cycleRecaps(d, now: now)
        XCTAssertEqual(c.count, 4)
        XCTAssertEqual(c[0].delta ?? 0, -2.6, accuracy: 1e-6)
        XCTAssertEqual(c[3].delta ?? 0, -0.7, accuracy: 1e-6)
        XCTAssertEqual(c[0].feel, "fading")
        XCTAssertEqual(c[3].ate, "less")
        XCTAssertEqual(c[1].foodNoise ?? 0, 4.714285714285714, accuracy: 1e-9)
        XCTAssertNil(c[0].vsPrevWeight)
        XCTAssertEqual(c[3].vsPrevWeight ?? 0, 2.0, accuracy: 1e-6)
        XCTAssertTrue(c[3].cycle.open)
        let w = T.wearOff(d, now: now)
        XCTAssertEqual(w.summary, "Wear-off pattern in 3 of 3 completed cycles.")
        XCTAssertEqual(w.details, ["Cycle 1: fading tags.", "Cycle 2: fading tags and late-cycle food noise rose.",
                                   "Cycle 3: fading tags and late-cycle food noise rose."])
        let f = T.feelReport(d)
        XCTAssertTrue(f.ready)
        XCTAssertEqual(f.count, 22)
        XCTAssertEqual(f.mood?.mean ?? 0, 7.2727272727272725, accuracy: 1e-9)
    }

    func testAppetiteByLevel() {
        let a = T.appetite(d, now: now)!
        XCTAssertEqual(a.noise.map(\.n), [11, 7, 4])
        XCTAssertEqual(a.noise[0].avg ?? 0, 5.545454545454546, accuracy: 1e-9)
        XCTAssertEqual(a.thoughts.map(\.n), [9, 4, 1])
        XCTAssertEqual(a.thoughts[0].perDay ?? 0, 2.057142857142857, accuracy: 1e-6)
        XCTAssertEqual(a.thoughts[2].perDay ?? 0, 0.3529411764705882, accuracy: 1e-6)
        XCTAssertEqual(a.trackedDays, 10.972222222222221, accuracy: 1e-6)
        XCTAssertEqual(a.nowShare ?? 0, 0.6057586161605162, accuracy: 1e-9)
        XCTAssertEqual(a.lead, "Food noise runs 3.0 points lower when the level is high than when it's low.")
    }

    func testOffNormal() {
        let r = T.offNormal(T.signalMaps(d), key: "2026-11-24")
        XCTAssertEqual(r.checked.map(\.def.id), ["resting_hr", "hrv_ms", "respiratory_rate", "wrist_temp_f"])
        XCTAssertEqual(r.checked.map(\.off), [true, true, true, false])
        XCTAssertEqual(r.checked.map(\.diffText), ["+8 bpm", "−42%", "+3.5/min", "−0.1°F"])
    }

    func testRetaBaseline() {
        let r = T.retaVsTirz(d, now: now)
        XCTAssertNil(r.reta)
        XCTAssertEqual(r.tirz.delta ?? 0, -9.1, accuracy: 1e-6)
        XCTAssertEqual(r.tirz.noise ?? 0, 4.523809523809524, accuracy: 1e-9)
        XCTAssertEqual(r.tirz.effectAvg ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(r.tirz.rhr ?? 0, 63.785714285714285, accuracy: 1e-9)
        XCTAssertEqual(r.tirz.burn ?? 0, 2833, accuracy: 1e-9)
        XCTAssertEqual(r.tirz.sleep ?? 0, 6.916785714285715, accuracy: 1e-9)
    }

    func testExplorerAndWall() {
        XCTAssertEqual(T.alignedPair(T.dailySeries(d, "weight"), T.dailySeries(d, "steps")).count, 73)
        XCTAssertEqual(T.thoughtsByDay(d, now: now).count, 11)
        XCTAssertEqual(T.earnDays(d, now: now).count, 56)
        XCTAssertTrue(T.prescriberCSV(d).hasPrefix("MEALS\neaten_at,meal_type,item"))
    }
}
