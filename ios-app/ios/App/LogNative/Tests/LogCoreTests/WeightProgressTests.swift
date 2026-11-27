import XCTest
@testable import LogCore

final class WeightProgressTests: XCTestCase {
    /// 60 days losing exactly 0.25 lb a day from 270, trend equal to the reading.
    func points() -> [WeightPoint] {
        let t0 = LogTime.noon("2026-09-01")
        return (0..<60).map { i in
            let lb = 270 - Double(i) * 0.25
            return WeightPoint(at: t0.addingTimeInterval(Double(i) * 86400), lb: lb, trend: lb)
        }
    }

    func testProgressAndMilestones() throws {
        let sm = points()
        let s = try XCTUnwrap(WeightProgress.make(sm, startLb: 270, goalLb: 240, now: sm.last!.at))
        XCTAssertEqual(s.current, 255.25, accuracy: 1e-9)
        XCTAssertEqual(s.done, 14.75, accuracy: 1e-9)
        XCTAssertEqual(s.toGo ?? 0, 15.25, accuracy: 1e-9)
        XCTAssertEqual(s.fraction ?? 0, 14.75 / 30, accuracy: 1e-9)
        XCTAssertEqual(s.weekly ?? 0, -1.75, accuracy: 1e-9)
        XCTAssertEqual(s.milestones.map(\.lb), [265, 260, 255, 250, 245, 240])
        XCTAssertNotNil(s.milestones[0].reached)
        XCTAssertNil(s.milestones[2].reached) // 255 not reached yet (trend 255.25)
        XCTAssertNotNil(s.milestones[2].eta)
        XCTAssertTrue(s.milestones.last!.isGoal)
        // 15.25 lb to go at 1.75 lb a week.
        let days = try XCTUnwrap(s.goalETA).timeIntervalSince(sm.last!.at) / 86400
        XCTAssertEqual(days, 15.25 / 1.75 * 7, accuracy: 1e-6)
        XCTAssertEqual(s.changes.first?.label, "1 week")
        XCTAssertEqual(s.changes.first?.delta ?? 0, -1.75, accuracy: 1e-9)
        XCTAssertEqual(s.changes.last?.label, "Since start")
        XCTAssertEqual(s.dayShift ?? 0, -0.25, accuracy: 1e-9)
    }

    /// Years-old Apple Health weigh-ins (190 lb in 2019) must not count as milestones reached.
    func testOldHistoryIsLeftOut() throws {
        let old = WeightPoint(at: LogTime.noon("2019-07-26"), lb: 190, trend: 190)
        let sm = [old] + points()
        let since = LogTime.noon("2026-09-01")
        let s = try XCTUnwrap(WeightProgress.make(sm, startLb: 270, goalLb: 240, since: since, now: sm.last!.at))
        XCTAssertEqual(s.lowest?.trend ?? 0, 255.25, accuracy: 1e-9)
        XCTAssertNil(s.milestones.last?.reached, "goal not reached yet")
        XCTAssertEqual(s.startDate, LogTime.noon("2026-09-01"))
        // A weigh-in a few days before the first shot is the run's start.
        let before = WeightPoint(at: LogTime.noon("2026-08-29"), lb: 271, trend: 271)
        XCTAssertEqual(WeightProgress.run([old, before] + points(), since: LogTime.noon("2026-08-31")).first, before)
    }

    /// A run younger than 4 weeks (first shot 3 weeks ago) still has a pace and goal dates.
    func testShortRunHasPace() throws {
        let sm = Array(points().suffix(22))
        let s = try XCTUnwrap(WeightProgress.make(sm, startLb: 260.5, goalLb: 240, since: sm[0].at, now: sm.last!.at))
        XCTAssertEqual(s.weekly ?? 0, -1.75, accuracy: 1e-9)
        XCTAssertNotNil(s.goalETA)
        XCTAssertNotNil(s.milestones.first { $0.reached == nil }?.eta)
    }

    /// A weigh-in under 260 ticks the 260 milestone even while the trend is still above it.
    func testWeighInTicksMilestone() throws {
        var sm = points()
        let last = sm[sm.count - 1]
        sm[sm.count - 1] = WeightPoint(at: last.at, lb: 254.6, trend: last.trend) // trend 255.25
        let s = try XCTUnwrap(WeightProgress.make(sm, startLb: 270, goalLb: 240, now: last.at))
        XCTAssertEqual(s.milestones.first { $0.lb == 255 }?.reached, last.at)
        XCTAssertEqual(s.lowestWeighIn?.lb ?? 0, 254.6, accuracy: 1e-9)
        XCTAssertEqual(s.lowest?.trend ?? 0, 255.25, accuracy: 1e-9)
    }

    func testRecentStartSkipsOldHistory() {
        let old = [WeightPoint(at: LogTime.noon("2019-07-26"), lb: 190, trend: 190),
                   WeightPoint(at: LogTime.noon("2019-08-02"), lb: 189, trend: 189.5)]
        let sm = old + points()
        XCTAssertEqual(WeightProgress.recentStart(sm), LogTime.noon("2026-09-01"))
        XCTAssertNil(WeightProgress.recentStart(points()))
    }

    func testNoGoalNoMilestones() throws {
        let s = try XCTUnwrap(WeightProgress.make(points(), startLb: nil, goalLb: nil, now: Date()))
        XCTAssertTrue(s.milestones.isEmpty)
        XCTAssertNil(s.goalETA)
        XCTAssertNil(WeightProgress.make([], startLb: 1, goalLb: 1, now: Date()))
    }
}

final class DataDigestTests: XCTestCase {
    func testDigestFromFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures"))
        let d = try Dashboard.decode(Data(contentsOf: url))
        let now = LogTime.parse("2026-11-24T23:20:00-06:00")!
        let full = DataDigest.make(d, now: now, size: .full)
        let compact = DataDigest.make(d, now: now, size: .compact)
        XCTAssertTrue(full.hasPrefix("Health log snapshot. Today is 2026-11-24"))
        XCTAssertTrue(full.contains("\n2026-11-24|"))
        XCTAssertTrue(full.contains("Weight: trend "))
        XCTAssertFalse(compact.contains("2026-11-01|"), "compact keeps two weeks")
        // Small enough for Apple Intelligence's context with room for a conversation.
        XCTAssertLessThan(compact.count, 6000)
        XCTAssertLessThan(compact.count, full.count)
    }
}

final class ReadinessTests: XCTestCase {
    func testRobustZ() throws {
        let base = Array(repeating: 50.0, count: 10) + [48, 52, 49, 51]
        let r = try XCTUnwrap(Readiness.robustZ(56, base: base, higherIsBetter: true, minSpread: 3))
        XCTAssertEqual(r.median, 50, accuracy: 1e-9)
        XCTAssertEqual(r.z, 2, accuracy: 1e-9) // spread floors at 3
        let low = try XCTUnwrap(Readiness.robustZ(56, base: base, higherIsBetter: false, minSpread: 3))
        XCTAssertEqual(low.z, -2, accuracy: 1e-9)
        XCTAssertNil(Readiness.robustZ(1, base: [1, 2, 3], higherIsBetter: true, minSpread: 1))
    }

    func testHistoryFromFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures"))
        let d = try Dashboard.decode(Data(contentsOf: url))
        let days = Readiness.history(d, now: LogTime.parse("2026-11-24T23:20:00-06:00")!)
        for day in days {
            XCTAssertTrue((0...10).contains(day.score))
            XCTAssertTrue(day.parts.contains { $0.id == "hrv" || $0.id == "rhr" })
        }
        XCTAssertEqual(days.map(\.key), days.map(\.key).sorted())
    }
}

final class AskToolsTests: XCTestCase {
    static var d: Dashboard = {
        let url = Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures")!
        return try! Dashboard.decode(Data(contentsOf: url))
    }()
    let now = LogTime.parse("2026-11-24T23:20:00-06:00")!

    func testDaysTable() {
        let out = AskTools.run("get_days", arguments: ["start": "2026-11-20", "end": "2026-11-24"], d: Self.d, now: now)
        XCTAssertTrue(out.hasPrefix("day|weight|trend|kcal"), out)
        XCTAssertTrue(out.contains("\n2026-11-24|"))
        XCTAssertFalse(out.contains("2026-11-19|"))
    }

    func testArgumentsAreChecked() {
        XCTAssertEqual(AskTools.run("get_days", arguments: ["start": "last week"], d: Self.d, now: now), "Give start and end as YYYY-MM-DD.")
        XCTAssertEqual(AskTools.run("nope", arguments: ["start": "2026-11-01", "end": "2026-11-02"], d: Self.d, now: now), "There's no tool called nope.")
        // Reversed dates and dates past today still work.
        let out = AskTools.run("get_doses", arguments: ["start": "2026-12-31", "end": "2026-11-01"], d: Self.d, now: now)
        XCTAssertFalse(out.isEmpty)
    }

    func testSchemasNameEveryTool() {
        XCTAssertEqual(AskTools.functionSchemas.count, AskTools.specs.count)
        XCTAssertEqual(AskTools.anthropicSchemas.compactMap { $0["name"] as? String }, AskTools.specs.map(\.name))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: AskTools.googleSchemas))
    }
}

final class CalorieBreakdownTests: XCTestCase {
    func decode<T: Decodable>(_ json: String) -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try! dec.decode(T.self, from: Data(json.utf8))
    }

    func testMacroSplitAndMeals() throws {
        let totals: DailyTotal = decode(#"{"date":"2026-11-24","calories":2000,"protein_g":150,"carbs_g":200,"fat_g":60,"fiber_g":25}"#)
        let meals: [Meal] = decode(#"""
        [{"eaten_at":"2026-11-24T08:00:00-06:00","meal_type":"breakfast","item":"Eggs","calories":500,"protein_g":40},
         {"eaten_at":"2026-11-24T12:30:00-06:00","meal_type":"Lunch","item":"Bowl","calories":700,"protein_g":50},
         {"eaten_at":"2026-11-24T19:00:00-06:00","item":"Salmon","calories":600,"protein_g":50},
         {"eaten_at":"2026-11-24T22:30:00-06:00","meal_type":"snacks","item":"Yogurt","calories":200,"protein_g":10}]
        """#)
        let b = try XCTUnwrap(CalorieBreakdown.make(meals: meals, totals: totals))
        XCTAssertEqual(b.calories, 2000)
        // 150 g protein = 600 kcal = 30%; 200 g carbs = 800 kcal; 60 g fat = 540 kcal.
        XCTAssertEqual(b.macros.map(\.id), ["protein", "carbs", "fat"], "60 kcal unaccounted is under the 5% floor")
        XCTAssertEqual(b.macros[0].share, 0.30, accuracy: 1e-9)
        XCTAssertEqual(b.macros[2].kcal, 540, accuracy: 1e-9)
        XCTAssertEqual(b.proteinPer100 ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(b.meals.map(\.label), ["Breakfast", "Lunch", "Dinner", "Snacks"], "untyped 7 PM meal counts as dinner")
        XCTAssertEqual(b.meals[1].share, 0.35, accuracy: 1e-9)
        XCTAssertEqual(b.fiber, 25)
    }

    func testCaloriesWithoutMacrosShowSeparately() throws {
        let totals: DailyTotal = decode(#"{"date":"2026-11-24","calories":2000,"protein_g":100,"carbs_g":100,"fat_g":40}"#)
        let b = try XCTUnwrap(CalorieBreakdown.make(meals: [], totals: totals))
        let other = try XCTUnwrap(b.macros.first { $0.id == "other" })
        XCTAssertEqual(other.kcal, 2000 - 1160, accuracy: 1e-9)
        XCTAssertEqual(b.macros.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
        XCTAssertNil(CalorieBreakdown.make(meals: [], totals: nil))
    }

    func testThirtyDayAverageFromFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "demo", withExtension: "json", subdirectory: "Fixtures"))
        let d = try Dashboard.decode(Data(contentsOf: url))
        let b = try XCTUnwrap(CalorieBreakdown.average(d, now: LogTime.parse("2026-11-24T23:20:00-06:00")!))
        XCTAssertGreaterThan(b.days, 1)
        XCTAssertLessThanOrEqual(b.macros.reduce(0) { $0 + $1.share }, 1.000001)
        XCTAssertEqual(CalorieBreakdown.targetDensity(protein: 150, calories: 2200) ?? 0, 150.0 / 22, accuracy: 1e-9)
    }
}
