import XCTest
@testable import LogCore

/// Core calculations against the web app's results on the same made-up fixture (tests/fixture.js,
/// regenerate with: node -e 'process.stdout.write(JSON.stringify(require("./tests/fixture").makeFixture()))').
/// Expected numbers came from running ios-app/www's own functions on that fixture.
final class LogCoreTests: XCTestCase {
    static var dashboard: Dashboard = {
        let url = Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures")!
        return try! Dashboard.decode(Data(contentsOf: url))
    }()
    let clock = LogTime.parse("2026-11-24T23:20:00-06:00")!

    func testDecodesEverySection() {
        let d = Self.dashboard
        XCTAssertEqual(d.weights.count, 128)
        XCTAssertFalse(d.meals.isEmpty)
        XCTAssertFalse(d.dailyHealth.isEmpty)
        XCTAssertEqual(d.healthMetrics.count, 10)
        XCTAssertEqual(d.protocols.count, 2)
        XCTAssertEqual(d.dosePlan.count, 13)
        XCTAssertEqual(d.profile?.heightIn, 70)
        XCTAssertEqual(d.doses.last?.doseMg, 3)
    }

    func testProgressPhotoDecodes() throws {
        let json = """
        {"as_of":"2026-11-24T23:20:00-06:00","progress_photos":[{"id":"p1","taken_at":"2026-11-18T14:00:00Z","day":"2026-11-18","weight_lb":"241.4","weight_id":"11111111-1111-4111-8111-111111111111","url":"https://example.test/p.jpg"}]}
        """.data(using: .utf8)!
        let d = try Dashboard.decode(json)
        XCTAssertEqual(d.progressPhotos.count, 1)
        XCTAssertEqual(d.progressPhotos[0].day, "2026-11-18")
        XCTAssertEqual(d.progressPhotos[0].weightLb ?? 0, 241.4, accuracy: 0.001)
        XCTAssertEqual(d.progressPhotos[0].weightId, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(d.progressPhotos[0].url, "https://example.test/p.jpg")
        XCTAssertEqual(d.meals.count, 0)
    }

    func testTimeKeys() {
        XCTAssertEqual(LogTime.dayKey(LogTime.parse("2026-11-25T05:20:00Z")!), "2026-11-24")
        XCTAssertEqual(LogTime.monday("2026-11-24"), "2026-11-23")
        XCTAssertEqual(LogTime.shift("2026-03-07", 2), "2026-03-09")
        XCTAssertEqual(LogTime.dayDiff("2026-12-06", "2026-11-24"), 12)
        XCTAssertEqual(LogTime.parse("2026-11-25T08:01:39.736092+00:00")?.timeIntervalSince1970 ?? 0, 1795593699.736092, accuracy: 0.001)
        XCTAssertEqual(LogTime.parse("2026-11-25 08:01:39.736092+00")?.timeIntervalSince1970 ?? 0, 1795593699.736092, accuracy: 0.001)
        XCTAssertEqual(LogTime.parse("2026-11-23T18:36:41-06:00"), LogTime.parse("2026-11-24T00:36:41Z"))
        XCTAssertEqual(LogTime.shortDate(key: "2026-11-24"), "Nov 24")
    }

    func testWeightTrend() {
        let sm = Analytics.smoothWeights(Self.dashboard)
        XCTAssertEqual(sm.count, 128)
        XCTAssertEqual(sm.last!.trend, 241.00383544877727, accuracy: 1e-9)
        XCTAssertEqual(Analytics.trendRate(sm, days: 28)!, -1.4504321324328018, accuracy: 1e-9)
    }

    func testDrugLevel() {
        let d = Self.dashboard
        XCTAssertEqual(Analytics.remaining(at: clock, doses: d.doses, protocols: d.protocols), 2.926036254935489, accuracy: 1e-9)
        XCTAssertEqual(Analytics.levelShare(at: clock, dashboard: d)!, 0.6057586161605162, accuracy: 1e-9)
    }

    func testPlanTotalsTargets() {
        let d = Self.dashboard
        let next = Analytics.nextPlanned(d, now: clock)
        XCTAssertEqual(next?.plannedOn, "2026-11-29")
        XCTAssertEqual(next?.doseMg, 3)
        let t = Analytics.totals(on: "2026-11-24", d)
        XCTAssertEqual(t?.calories, 1615)
        XCTAssertEqual(t?.proteinG, 62)
        XCTAssertNil(Analytics.targets(d).calories)
    }

    func testRollingMean() {
        let v = [DayValue(key: "2026-11-01", value: 1), DayValue(key: "2026-11-02", value: 3), DayValue(key: "2026-11-09", value: 5)]
        let r = Analytics.rollingMean(v, days: 7)
        XCTAssertEqual(r.map(\.value), [1, 2, 5])
    }
}
