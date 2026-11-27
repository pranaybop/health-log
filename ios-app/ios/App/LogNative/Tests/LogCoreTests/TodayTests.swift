import XCTest
@testable import LogCore

final class TodayTests: XCTestCase {
    var d: Dashboard { LogCoreTests.dashboard }
    let clock = LogTime.parse("2026-11-24T23:20:00-06:00")!

    func testPaceJourneyAndStall() {
        let pts = Analytics.smoothWeights(d)
        let rp = Analytics.recentPace(pts, days: 28)
        XCTAssertEqual(rp?.weekly ?? 0, -2.817939543419389, accuracy: 1e-6)
        XCTAssertEqual(rp?.fittedNow ?? 0, 238.638335364273, accuracy: 1e-6)
        XCTAssertEqual(rp?.count, 23)
        let loss = Analytics.lossRate(pts)
        XCTAssertEqual(loss?.pct ?? 0, 1.181030822891613, accuracy: 1e-6)
        XCTAssertEqual(loss?.fast, true)
        let j = Analytics.journey(d)
        XCTAssertEqual(j?.current.lb, 238.6)
        XCTAssertEqual(j?.startLb, 248)
        XCTAssertEqual(j?.goalLb, 215)
        XCTAssertEqual(j?.changeStart ?? 0, -9.4, accuracy: 1e-9)
        let stall = Analytics.stallCheck(pts, now: clock)
        XCTAssertFalse(stall.stalled)
        XCTAssertTrue(stall.ready)
        XCTAssertEqual(stall.weekly ?? 0, -2.9976205542221264, accuracy: 1e-6)
        XCTAssertEqual(stall.change ?? 0, -7.8, accuracy: 1e-9)
        let endOf23 = LogTime.noon("2026-11-23").addingTimeInterval(12 * 3600)
        XCTAssertEqual(Analytics.trend(at: endOf23, in: pts) ?? 0, 241.4397960382286, accuracy: 1e-9)
    }

    func testDaysDosesAndLevel() {
        XCTAssertEqual(Analytics.earliestDay(d, now: clock), "2024-11-04")
        let logged = Analytics.loggedDays(d)
        XCTAssertTrue(logged.contains("2026-11-24"))
        XCTAssertTrue(logged.contains("2026-11-23"))
        XCTAssertEqual(Analytics.plannedNextDose(d), LogTime.parse("2026-11-29T16:00:00Z"))
        XCTAssertEqual(Analytics.retaSwitchAt(d), LogTime.noon("2026-12-06"))
        let at = LogTime.noon("2026-11-23").addingTimeInterval(9 * 3600)
        XCTAssertEqual(Analytics.remaining(at: at, doses: d.doses, protocols: d.protocols), 3.406740575045724, accuracy: 1e-9)
    }

    func testSleep() {
        XCTAssertEqual(Analytics.sleepHours(d, on: "2026-11-24"), 6.2)
        let s = Analytics.sleepStages(d, on: "2026-11-24")
        XCTAssertNil(s?.core)
        XCTAssertEqual(s?.deep, 63)
        XCTAssertEqual(s?.rem, 88)
        XCTAssertNil(s?.awake)
        XCTAssertEqual(Analytics.nightKey(d, view: "2026-11-24", now: clock), "2026-11-24")
    }

    func testOffNormal() {
        let c = Analytics.offNormal(d, on: "2026-11-24")
        XCTAssertEqual(c.map(\.spec.id), ["resting_hr", "hrv_ms", "respiratory_rate", "wrist_temp_f"])
        XCTAssertEqual(c.map(\.off), [true, true, true, false])
        XCTAssertEqual(c[0].value, 72)
        XCTAssertEqual(c[0].median, 64)
        XCTAssertEqual(c[1].median, 53)
        XCTAssertEqual(c[2].diff, 3.5, accuracy: 1e-9)
        XCTAssertEqual(c[3].median, 95.535, accuracy: 1e-9)
    }

    func testProtein() {
        let p = Analytics.proteinStreak(d, target: 60, now: clock)
        XCTAssertEqual(p.streak, 1)
        XCTAssertTrue(p.hitToday)
        XCTAssertEqual(p.remaining, 0)
        XCTAssertEqual(p.todayProtein, 62)
        let q = Analytics.proteinStreak(d, target: 150, now: clock)
        XCTAssertEqual(q.streak, 0)
        XCTAssertFalse(q.hitToday)
        XCTAssertEqual(q.remaining, 88)
    }
}
