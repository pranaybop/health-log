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

    func testWeights() {
        XCTAssertEqual(Readiness.weights, [
            "hrv": 0.24, "rhr": 0.20, "sleep": 0.16, "stages": 0.10,
            "temp": 0.08, "resp": 0.07, "spo2": 0.05, "load": 0.10,
        ])
        XCTAssertEqual(Readiness.weights.values.reduce(0, +), 1, accuracy: 1e-12)
    }

    /// No reading, or fewer than 7 baseline days, drops that signal and rescales the rest.
    func testMissingSignalsRenormalize() throws {
        let heart = try dashboard(health: heartRows(hrv: 50, rhr: 55, todayHrv: 56, todayRhr: 55))
        let onlyHeart = try XCTUnwrap(Readiness.day(dayKey, d: heart, load: [:]))
        XCTAssertEqual(onlyHeart.parts.map(\.id), ["hrv", "rhr"])
        XCTAssertEqual(onlyHeart.parts[0].z, 2, accuracy: 1e-9) // (56 - 50) / 3
        XCTAssertEqual(onlyHeart.parts[1].z, 0, accuracy: 1e-9)
        XCTAssertEqual(onlyHeart.score, score(from: [("hrv", 2), ("rhr", 0)]), accuracy: 1e-9)
        for part in onlyHeart.parts { XCTAssertEqual(part.weight, Readiness.weights[part.id]!) }

        // Today's value is present, but the baseline is short of 7 days: same as no data.
        let short = try dashboard(
            health: heartRows(hrv: 50, rhr: 55, todayHrv: 56, todayRhr: 55, sleepDays: 6, sleep: 8, todaySleep: 5),
            metrics: [
                "spo2_avg": series(97, days: 6, today: 90),
                "wrist_temp_f": series(95, days: 6, today: 97),
                "sleep_deep_min": series(80, days: 10, today: 80),
                "respiratory_rate": series(14, days: 6, today: 18),
            ])
        let dropped = try XCTUnwrap(Readiness.day(dayKey, d: short, load: [:]))
        XCTAssertEqual(dropped.parts.map(\.id), ["hrv", "rhr"], "short baselines and a stage with no REM stay out")
        XCTAssertEqual(dropped.score, onlyHeart.score, accuracy: 1e-9)

        // Seven baseline days of a normal SpO2 still take their share, so HRV moves the score less.
        let withOxygen = try dashboard(
            health: heartRows(hrv: 50, rhr: 55, todayHrv: 56, todayRhr: 55),
            metrics: ["spo2_avg": series(97, days: 7, today: 97)])
        let diluted = try XCTUnwrap(Readiness.day(dayKey, d: withOxygen, load: [:]))
        XCTAssertEqual(diluted.parts.map(\.id), ["hrv", "rhr", "spo2"])
        XCTAssertEqual(diluted.parts[2].z, 0, accuracy: 1e-9)
        XCTAssertEqual(diluted.parts[2].weight, 0.05, accuracy: 1e-12)
        XCTAssertEqual(diluted.score, score(from: [("hrv", 2), ("rhr", 0), ("spo2", 0)]), accuracy: 1e-9)
        XCTAssertNotEqual(diluted.score, onlyHeart.score)

        // Watch-only days still don't score.
        let noHeart = try dashboard(health: [], metrics: ["spo2_avg": series(97, days: 10, today: 97)])
        XCTAssertNil(Readiness.day(dayKey, d: noHeart, load: [:]))
    }

    func testWatchSignalsUseTheBaseline() throws {
        let d = try dashboard(
            health: heartRows(hrv: 50, rhr: 55, todayHrv: 50, todayRhr: 55),
            metrics: [
                "sleep_deep_min": series(60, days: 10, today: 80),
                "sleep_rem_min": series(40, days: 10, today: 40),
                "wrist_temp_f": series(95, days: 10, today: 96.5),
                "respiratory_rate": series(14, days: 10, today: 16),
                "spo2_avg": series(98, days: 10, today: 96),
            ])
        let day = try XCTUnwrap(Readiness.day(dayKey, d: d, load: [:]))
        let byId = Dictionary(uniqueKeysWithValues: day.parts.map { ($0.id, $0) })
        let stages = try XCTUnwrap(byId["stages"])
        XCTAssertEqual(stages.value, 120, accuracy: 1e-9) // 80 deep + 40 REM, against 100
        XCTAssertEqual(stages.normal, 100, accuracy: 1e-9)
        XCTAssertEqual(stages.z, 1, accuracy: 1e-9) // 20 minutes / the 20-minute floor
        // Warmer wrist, faster breathing and lower SpO2 all score worse.
        XCTAssertEqual(try XCTUnwrap(byId["temp"]).z, -3, accuracy: 1e-9) // (1.5 °F / 0.3) capped
        XCTAssertEqual(try XCTUnwrap(byId["resp"]).z, -3, accuracy: 1e-9) // (2 / 0.5) capped
        XCTAssertEqual(try XCTUnwrap(byId["spo2"]).z, -2.5, accuracy: 1e-9) // -2 / 0.8
        XCTAssertEqual(day.score, score(from: [("hrv", 0), ("rhr", 0), ("stages", 1), ("temp", -3), ("resp", -3), ("spo2", -2.5)]), accuracy: 1e-9)
    }

    func testTrainingLoadMovesTheScore() throws {
        let d = try dashboard(health: heartRows(hrv: 50, rhr: 55, todayHrv: 50, todayRhr: 55))
        let matched = try XCTUnwrap(Readiness.day(dayKey, d: d, load: loadMap(acute: 100, other: 100)))
        XCTAssertEqual(try XCTUnwrap(matched.parts.first { $0.id == "load" }).z, 0, accuracy: 1e-9)
        XCTAssertEqual(matched.score, 5, accuracy: 1e-9)

        // 25 days at 94 and 3 recent days at 150: chronic load 100, one spread worse.
        let heavy = try XCTUnwrap(Readiness.day(dayKey, d: d, load: loadMap(acute: 150, other: 94)))
        let heavyLoad = try XCTUnwrap(heavy.parts.first { $0.id == "load" })
        XCTAssertEqual(heavyLoad.z, -1, accuracy: 1e-9)
        XCTAssertEqual(heavyLoad.weight, 0.10, accuracy: 1e-12)
        XCTAssertEqual(heavyLoad.value, 150, accuracy: 1e-9)
        XCTAssertEqual(heavyLoad.normal, 100, accuracy: 1e-9)
        XCTAssertLessThan(heavy.score, matched.score)
        XCTAssertEqual(heavy.score, score(from: [("hrv", 0), ("rhr", 0), ("load", -1)]), accuracy: 1e-9)

        let light = try XCTUnwrap(Readiness.day(dayKey, d: d, load: loadMap(acute: 50, other: 100)))
        XCTAssertGreaterThan(try XCTUnwrap(light.parts.first { $0.id == "load" }).z, 0)
        XCTAssertGreaterThan(light.score, matched.score)

        // Three trained days in the window is not enough history, so load is left out.
        var sparse: [String: Double] = [:]
        for day in baselineDays(3) { sparse[day] = 200 }
        let tooFew = try XCTUnwrap(Readiness.day(dayKey, d: d, load: sparse))
        XCTAssertFalse(tooFew.parts.contains { $0.id == "load" })
        XCTAssertEqual(tooFew.score, matched.score, accuracy: 1e-9)
    }

    func testWhatMovedLine() throws {
        XCTAssertEqual(moved([("sleep", -2, 0.16), ("hrv", 1, 0.22), ("rhr", 0.4, 0.20), ("temp", -3, 0.08)]),
                       "Sleep was short, and wrist temperature is up.")
        // Equal |z × weight| breaks by id, and a third tie is not named.
        XCTAssertEqual(moved([("temp", 1, 0.08), ("spo2", -1, 0.08), ("resp", 1, 0.08)]),
                       "Breathing rate is lower than usual, and blood oxygen is below your normal.")
        XCTAssertEqual(moved([("hrv", 0.5, 0.24), ("load", -0.49, 0.10)]), "HRV is above your normal.")
        XCTAssertEqual(moved([("hrv", 0.49, 0.24), ("rhr", -0.2, 0.20)]), "Everything used is close to your normal.")
        XCTAssertEqual(moved([]), "Everything used is close to your normal.")
        XCTAssertEqual(moved([("hrv", 1, 0.24)], dose: 0), "HRV is above your normal. Shot day.")
        XCTAssertEqual(moved([("hrv", -1, 0.24)], dose: 2), "HRV is below your normal. Day 2 after a shot.")
        XCTAssertEqual(moved([("hrv", 1, 0.24)], dose: 3), "HRV is above your normal.")
        XCTAssertEqual(moved([("load", -1.2, 0.10)]), "Recent training is heavier than usual.")
        XCTAssertEqual(moved([("load", 1, 0.10)]), "Recent training is lighter than usual.")
        XCTAssertEqual(moved([("stages", 1, 0.10)]), "Deep and REM sleep are up.")
        XCTAssertEqual(moved([("stages", -1, 0.10)]), "Deep and REM sleep are down.")
        XCTAssertEqual(moved([("rhr", 1, 0.20)]), "Resting heart rate is lower than usual.")
        XCTAssertEqual(moved([("rhr", -1, 0.20)]), "Resting heart rate is up.")
        XCTAssertEqual(moved([("sleep", 1, 0.16)]), "You slept more than usual.")
        XCTAssertEqual(moved([("temp", 1, 0.08)]), "Wrist temperature is below your normal.")
        XCTAssertEqual(moved([("resp", -1, 0.08)]), "Breathing rate is up.")
        XCTAssertEqual(moved([("spo2", 1, 0.06)]), "Blood oxygen is above your normal.")
        XCTAssertEqual(moved([("spo2", -1, 0.06)]), "Blood oxygen is below your normal.")
        XCTAssertEqual(moved([("sleep", -2, 0.16), ("hrv", -1, 0.24)]), "Sleep was short, and HRV is below your normal.")

        let line = moved([("sleep", -2, 0.16), ("temp", -3, 0.08)])
        XCTAssertEqual(line, moved([("sleep", -2, 0.16), ("temp", -3, 0.08)]))
        XCTAssertEqual(line, "Sleep was short, and wrist temperature is up.")

        // The scorer and the sentence agree on a day whose HRV and wrist temperature are both far off.
        let d = try dashboard(
            health: heartRows(hrv: 50, rhr: 55, todayHrv: 80, todayRhr: 55),
            metrics: ["wrist_temp_f": series(95, days: 10, today: 97)])
        let day = try XCTUnwrap(Readiness.day(dayKey, d: d, load: [:]))
        XCTAssertEqual(Readiness.whatMoved(day), "HRV is above your normal, and wrist temperature is up.")
        XCTAssertEqual(Readiness.whatMoved(day), Readiness.whatMoved(day))
    }

    private let dayKey = "2026-11-24"

    private func baselineDays(_ n: Int) -> [String] {
        (1...n).map { LogTime.shift(dayKey, -$0) }
    }

    private func heartRows(hrv: Double, rhr: Double, todayHrv: Double, todayRhr: Double,
                           sleepDays: Int = 0, sleep: Double = 7, todaySleep: Double? = nil) -> [[String: Any]] {
        var rows: [[String: Any]] = baselineDays(10).enumerated().map { i, day in
            var row: [String: Any] = ["day": day, "hrv_ms": hrv, "resting_hr": rhr]
            if i < sleepDays { row["sleep_hours"] = sleep }
            return row
        }
        var today: [String: Any] = ["day": dayKey, "hrv_ms": todayHrv, "resting_hr": todayRhr]
        if let todaySleep { today["sleep_hours"] = todaySleep }
        rows.append(today)
        return rows
    }

    /// `days` baseline values, oldest irrelevant, plus today.
    private func series(_ baseline: Double, days: Int, today: Double) -> [[Any]] {
        baselineDays(days).map { [$0, baseline] } + [[dayKey, today]]
    }

    /// Acute load on the 3 days before `dayKey`, `other` on the 25 days before those.
    private func loadMap(acute: Double, other: Double) -> [String: Double] {
        var m: [String: Double] = [:]
        for (i, day) in baselineDays(28).enumerated() { m[day] = i < 3 ? acute : other }
        return m
    }

    private func dashboard(health: [[String: Any]], metrics: [String: [[Any]]] = [:]) throws -> Dashboard {
        let obj: [String: Any] = ["daily_health": health, "health_metrics": metrics, "workouts": [] as [Any]]
        return try Dashboard.decode(JSONSerialization.data(withJSONObject: obj))
    }

    /// The published score from locked weights: 5 + 5/3 × the renormalized weighted mean, to 0.1.
    private func score(from parts: [(String, Double)]) -> Double {
        let weights = Readiness.weights
        let total = parts.reduce(0.0) { $0 + weights[$1.0]! }
        let mean = parts.reduce(0.0) { $0 + $1.1 * weights[$1.0]! } / total
        return (max(0, min(10, 5 + mean * 5 / 3)) * 10).rounded() / 10
    }

    /// `(id, z, weight)` parts, in the order given.
    private func moved(_ parts: [(String, Double, Double)], dose: Int? = nil) -> String {
        let built = parts.map { Readiness.Part(id: $0.0, label: $0.0, value: 0, normal: 0, z: $0.1, weight: $0.2, unit: "") }
        let day = Readiness.Day(key: dayKey, score: 5, parts: built, daysSinceDose: dose, calories: nil, weightTrend: nil)
        return Readiness.whatMoved(day)
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
