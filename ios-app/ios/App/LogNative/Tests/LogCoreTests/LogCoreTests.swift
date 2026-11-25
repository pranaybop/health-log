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
        let next = Analytics.nextPlanned(d)
        XCTAssertEqual(next?.plannedOn, "2026-11-29")
        XCTAssertEqual(next?.doseMg, 3)
        XCTAssertFalse(Analytics.planIsOverdue(next!, now: clock))
        let t = Analytics.totals(on: "2026-11-24", d)
        XCTAssertEqual(t?.calories, 1615)
        XCTAssertEqual(t?.proteinG, 62)
        XCTAssertNil(Analytics.targets(d).calories)
    }

    /// A missed Sunday stays the next dose until a taken or skipped dose lands in that week.
    func testMissedPlanStaysUntilLoggedOrSkipped() {
        let d = Self.dashboard
        let monday = LogTime.parse("2026-11-30T09:00:00-06:00")!
        let missed = Analytics.nextPlanned(d)
        XCTAssertEqual(missed?.plannedOn, "2026-11-29")
        XCTAssertEqual(Analytics.openPlan(d).first?.plannedOn, "2026-11-29")
        XCTAssertTrue(Analytics.planIsOverdue(missed!, now: monday))

        var loggedLate = d
        var late = loggedLate.doses[0]
        late.takenAt = "2026-11-30T18:00:00Z"
        late.skipped = false
        loggedLate.doses.append(late)
        XCTAssertEqual(Analytics.nextPlanned(loggedLate)?.plannedOn, "2026-12-06")
        XCTAssertFalse(Analytics.planIsOverdue(Analytics.nextPlanned(loggedLate)!, now: monday))

        var skippedWeek = d
        var skip = skippedWeek.doses[0]
        skip.takenAt = "2026-11-30T16:00:00Z"
        skip.skipped = true
        skippedWeek.doses.append(skip)
        XCTAssertEqual(Analytics.nextPlanned(skippedWeek)?.plannedOn, "2026-12-06")

        var onPlannedDay = d
        var exact = onPlannedDay.doses[0]
        exact.takenAt = "2026-11-29T18:00:00Z"
        exact.skipped = true
        exact.doseMg = nil
        onPlannedDay.doses.append(exact)
        XCTAssertEqual(Analytics.nextPlanned(onPlannedDay)?.plannedOn, "2026-12-06")

        // Logging the following Sunday does not erase the week that was missed.
        var onlyNext = d
        var nextWeek = onlyNext.doses[0]
        nextWeek.takenAt = "2026-12-06T18:00:00Z"
        nextWeek.skipped = false
        onlyNext.doses.append(nextWeek)
        XCTAssertEqual(Analytics.nextPlanned(onlyNext)?.plannedOn, "2026-11-29")
        let afterNext = LogTime.parse("2026-12-07T12:00:00-06:00")!
        XCTAssertTrue(Analytics.planIsOverdue(Analytics.nextPlanned(onlyNext)!, now: afterNext))

        let bothOpen = d
        let dec8 = LogTime.parse("2026-12-08T09:00:00-06:00")!
        XCTAssertEqual(Analytics.nextPlanned(bothOpen)?.plannedOn, "2026-11-29")
        XCTAssertTrue(Analytics.planIsOverdue(Analytics.nextPlanned(bothOpen)!, now: dec8))
        var cleared = bothOpen
        var firstSkip = cleared.doses[0]
        firstSkip.takenAt = "2026-11-29T18:00:00Z"
        firstSkip.skipped = true
        cleared.doses.append(firstSkip)
        XCTAssertEqual(Analytics.nextPlanned(cleared)?.plannedOn, "2026-12-06")
        XCTAssertTrue(Analytics.planIsOverdue(Analytics.nextPlanned(cleared)!, now: dec8))
    }

    func testRollingMean() {
        let v = [DayValue(key: "2026-11-01", value: 1), DayValue(key: "2026-11-02", value: 3), DayValue(key: "2026-11-09", value: 5)]
        let r = Analytics.rollingMean(v, days: 7)
        XCTAssertEqual(r.map(\.value), [1, 2, 5])
    }
}
