import XCTest
@testable import LogCore

final class MedsTests: XCTestCase {
    var d: Dashboard { LogCoreTests.dashboard }

    func testPlannedShot() {
        let p = Analytics.plannedShots(d.doses, protocols: d.protocols)
        XCTAssertEqual(p.next, LogTime.parse("2026-11-29T16:00:00Z"))
        XCTAssertEqual(p.withNext.count, 5)
        XCTAssertEqual(p.withNext.last?.mg, 3)
        XCTAssertEqual(p.withNext.last?.planned, true)
    }

    func testLevelPoints() throws {
        let now = LogTime.parse("2026-11-24T23:20:00-06:00")!
        let lp = try XCTUnwrap(Analytics.levelPoints(d, now: now))
        XCTAssertEqual(lp.logged.count, 151)
        XCTAssertEqual(lp.withNext.count, 151)
        XCTAssertEqual(lp.start, LogTime.parse("2026-11-02T16:00:00Z"))
        XCTAssertEqual(lp.end, LogTime.parse("2026-12-09T05:20:00Z"))
        XCTAssertEqual(lp.logged.map(\.v).max()!, 4.170032872004458, accuracy: 1e-9)
        XCTAssertEqual(lp.logged.last!.v, 0.423389899146237, accuracy: 1e-9)
        XCTAssertEqual(lp.withNext.last!.v, 1.2272199960484569, accuracy: 1e-9)
        XCTAssertEqual(lp.logged[100].t, LogTime.parse("2026-11-26T22:00:00Z"))
        XCTAssertEqual(lp.logged[100].v, 2.313470586147773, accuracy: 1e-9)
    }

    /// No planned switch must not sample out to the far future.
    func testLevelPointsNilSwitchIsBounded() throws {
        let saved = LogTime.switchStart
        LogTime.switchStart = nil
        defer { LogTime.switchStart = saved }
        let now = LogTime.parse("2026-11-24T23:20:00-06:00")!
        let lp = try XCTUnwrap(Analytics.levelPoints(d, now: now))
        let last = try XCTUnwrap(d.doses.compactMap(\.takenDate).max())
        XCTAssertEqual(lp.end, max(now, last).addingTimeInterval(14 * 86400))
        XCTAssertLessThan(lp.logged.count, 400)
        XCTAssertEqual(lp.logged.count, lp.withNext.count)
    }

    func testSitesAndTitration() {
        let rot = Analytics.siteRotation(d)
        XCTAssertEqual(rot.lastSite, "Love L")
        XCTAssertEqual(rot.next, "Love R")
        XCTAssertEqual(Analytics.titrationHistory(d.doses).map(\.changed), [true, false, false, true])
    }

    func testPlanSteps() {
        let rows = Analytics.planRows(d)
        XCTAssertEqual(rows.count, 13)
        let steps = Analytics.planSteps(rows)
        XCTAssertEqual(steps.map(\.from), ["2026-11-29", "2026-12-06", "2027-01-03", "2027-01-31"])
        XCTAssertEqual(steps.map(\.to), ["2026-11-29", "2026-12-27", "2027-01-24", "2027-02-21"])
        XCTAssertEqual(steps.map(\.weeks), [1, 4, 4, 4])
        XCTAssertEqual(steps.map(\.doseMg), [3, 2, 3, 4])
    }

    func testVialsAndSwitch() {
        let now = LogTime.parse("2026-11-24T23:20:00-06:00")!
        let r = Analytics.vialRunway(d, now: now)
        XCTAssertTrue(r.ready)
        XCTAssertEqual(r.soonest?.vial.id, "v1")
        XCTAssertEqual(r.soonest?.weeks, 1)
        let tirz = Analytics.compoundRunway(d, "tirzepatide", now: now)
        XCTAssertEqual(tirz.mg, 3)
        XCTAssertEqual(tirz.weeks, 1)
        let reta = Analytics.compoundRunway(d, "retatrutide", now: now)
        XCTAssertEqual(reta.mg, 34)
        XCTAssertNil(reta.units)
        XCTAssertNil(reta.weeks)
        XCTAssertEqual(Analytics.retaSwitchAt(d), Optional(LogTime.noon("2026-12-06")))
        XCTAssertNil(Analytics.firstRetaDose(d))
        var dose = d.doses[0]
        dose.site = nil
        dose.notes = "test; site Abd UL; more"
        XCTAssertEqual(Analytics.siteLabel(dose), "Upper left belly")
    }
}
