import XCTest
import HealthKit
@testable import LogHealth
import LogCore

/// The Apple Health sync's pure parts against health.js on the same made-up samples (no real
/// health data). Expected values came from running the old web app's health.js collectWindow on these
/// samples with a stand-in plugin.
final class LogHealthTests: XCTestCase {
    let a = "2026-11-23"
    let b = "2026-11-24"
    let old = "2026-11-10"

    /// Central hour `h` on day `k` (like the web test's at(): noon CST plus h - 12 hours, whole ms).
    func at(_ k: String, _ h: Double) -> Date {
        let ms = (LogTime.noon(k).timeIntervalSince1970 * 1000 + (h - 12) * 3_600_000).rounded(.towardZero)
        return Date(timeIntervalSince1970: ms / 1000)
    }

    func s(_ k: String, _ h0: Double, _ h1: Double, _ v: Double, _ src: String, unit: String? = "count",
           state: String? = nil, sys: Double? = nil, dia: Double? = nil) -> HealthSample {
        HealthSample(start: at(k, h0), end: at(k, h1), value: v, unit: unit, source: src, sleepState: state, systolic: sys, diastolic: dia)
    }

    func window() -> HealthWindowSamples {
        var w = HealthWindowSamples()
        w.steps = [a: HealthDayStat(sum: 9123.5), b: HealthDayStat(sum: 4000.4)]
        w.distance = [a: HealthDayStat(sum: 6437.4)]
        w.active = [a: HealthDayStat(sum: 812.4), b: HealthDayStat(sum: 300.5)]
        w.restingHr = [a: HealthDayStat(average: 57.6)]
        w.heartRate = [a: HealthDayStat(average: 72.44, min: 48.4, max: 151.5)]
        w.water = [a: HealthDayStat(sum: 1.5)]
        w.dietary = [b: HealthDayStat(sum: 1850.6)]
        w.exercise = [9.0, 12.0, 18.0].map { s(a, $0, $0 + 1.0 / 6, 10, "watch") } + [s(a, 7, 7.2, 12, "phone")]
        w.stand = (8..<21).map { h in s(a, Double(h), Double(h + 1), h < 19 ? 1 : 0, "watch") }
        w.vo2 = [s(b, 15, 15, 38.44, "watch"), s(b, 16, 16, 39.06, "watch")]
        w.hrv = [s(b, 3, 3, 60, "watch"), s(b, 9, 9, 82, "watch")]
        w.sleep = [
            s(b, -1 - 1.0 / 3, -1, 20, "watch", state: "light"), // 10:40-11 pm the evening before
            s(b, -1, 3, 240, "watch", state: "light"),
            s(b, 3, 4, 60, "watch", state: "awake"),
            s(b, 4, 7, 180, "watch", state: "deep"),
            s(b, 14, 14.5, 30, "watch", state: "rem"),           // a nap: its own session, same day
            s(b, 0, 6, 360, "autosleep", state: "asleep"),
            s(b, -1.5, 7.25, 525, "phone", state: "inBed"),
        ]
        w.basal = (0..<24).map { h in s(a, Double(h), Double(h + 1), 80, "watch") } + [s(a, 12, 13, 1500, "phone")]
        w.flights = [s("2026-11-22", 10, 10.1, 30, "watch"), s(a, 10, 10.1, 6, "watch"), s(a, 10, 10.1, 8, "phone")]
        w.cycling = [s(b, 9, 10, 5000, "watch")]
        w.glucose = [s(b, 7, 7, 92, "meter"), s(b, 13, 13, 110, "meter"), s(b, 19, 19, 101.3, "meter")]
        w.bodyTemp = [s(a, 8, 8, 36.8, "phone", unit: "celsius")]
        w.basalTemp = [s(b, 6, 6, 97.9, "phone", unit: "fahrenheit")]
        w.wristTemp = [s(b, 3, 3, 35.1, "watch", unit: "celsius")]
        w.resp = [s(b, 2, 2, 14, "watch"), s(b, 4, 4, 16.5, "watch")]
        w.spo2 = [s(b, 2, 2, 0.97, "watch"), s(b, 4, 4, 0.94, "watch")]
        w.bloodPressure = [s(b, 8, 8, 118, "cuff", sys: 118, dia: 76), s(b, 20, 20, 122, "cuff", sys: 122, dia: 80)]
        w.mindful = [s(b, 8, 8 + 1.0 / 6, 10, "watch"), s(b, 8, 8 + 1.0 / 6, 10, "phone")]
        w.mood = [s(b, 9, 9, 0.4, "phone"), s(b, 20, 20, -0.2, "phone")]
        w.height = [s(b, 8, 8, 185.42, "phone"), s(b, 9, 9, 180, "phone")]
        w.weights = [s(old, 8, 8, 90, "scale", unit: "kilogram"), s(b, 8, 8, 116.665, "scale", unit: "kilogram")]
        w.bodyFat = [s(old, 12, 12, 0.25, "scale"), s(b, 8 + 1.0 / 60, 8 + 1.0 / 60, 0.368, "scale")]
        w.workouts = [
            HealthWorkoutSample(start: at(a, 7), end: at(a, 7.75), type: "running", durationSeconds: 2701,
                                distanceMeters: 8046.72, energyKcal: 512.6, indoor: "0"),
            HealthWorkoutSample(start: at(b, 18), end: at(b, 18.35), type: "highIntensityIntervalTraining", durationSeconds: 1234),
        ]
        return w
    }

    // MARK: The window, against health.js

    func testDailyTotals() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        XCTAssertEqual(batch.days.count, 2)
        var dayA = HealthDayRow(day: a)
        dayA.steps = 9124
        dayA.distanceMi = 4
        dayA.activeKcal = 812
        dayA.restingHr = 58
        dayA.exerciseMin = 30   // the watch's 30, not watch + phone
        dayA.standHours = 11
        var dayB = HealthDayRow(day: b)
        dayB.steps = 4000
        dayB.activeKcal = 301   // 300.5 rounds up, like Math.round
        dayB.vo2max = 39.1
        dayB.hrvMs = 71
        dayB.sleepHours = 7.83  // the watch's night (with its nap), credited to the day you woke up
        XCTAssertEqual(batch.days, [dayA, dayB])
    }

    func testNoDailyTotalsInBackfill() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: false)
        XCTAssertTrue(batch.days.isEmpty)
        XCTAssertEqual(batch.metrics.count, 28)
    }

    func testMetrics() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        let expected: [String: (Double, String)] = [
            "\(b)|sleep_deep_min": (180, "min"), "\(b)|sleep_rem_min": (30, "min"), "\(b)|sleep_core_min": (260, "min"),
            "\(b)|sleep_awake_min": (60, "min"), "\(b)|sleep_in_bed_h": (8.75, "h"),
            "\(a)|heart_rate_avg": (72.4, "bpm"), "\(a)|heart_rate_min": (48, "bpm"), "\(a)|heart_rate_max": (152, "bpm"),
            "\(a)|basal_kcal": (1920, "kcal"), "\(a)|total_kcal": (2732, "kcal"), "\(a)|flights": (8, "count"),
            "\(b)|cycling_mi": (3.11, "mi"), "\(a)|water_oz": (51, "fl oz"), "\(b)|dietary_kcal": (1851, "kcal"),
            "\(b)|glucose_avg": (101, "mg/dL"), "\(b)|glucose_min": (92, "mg/dL"), "\(b)|glucose_max": (110, "mg/dL"),
            "\(a)|body_temp_f": (98.2, "°F"), "\(b)|basal_temp_f": (97.9, "°F"), "\(b)|wrist_temp_f": (95.18, "°F"),
            "\(b)|respiratory_rate": (15.3, "/min"), "\(b)|spo2_avg": (95.5, "%"), "\(b)|spo2_min": (94, "%"),
            "\(b)|bp_systolic": (120, "mmHg"), "\(b)|bp_diastolic": (78, "mmHg"), "\(b)|mindful_min": (10, "min"),
            "\(b)|state_of_mind": (0.1, "valence"), "\(b)|height_in": (70.9, "in"),
        ]
        XCTAssertEqual(batch.metrics.count, expected.count)
        for m in batch.metrics {
            let key = "\(m.day)|\(m.metric)"
            guard let e = expected[key] else { XCTFail("unexpected \(key)"); continue }
            XCTAssertEqual(m.value, e.0, key)
            XCTAssertEqual(m.unit, e.1, key)
        }
        XCTAssertEqual(batch.metrics.first?.metric, "sleep_deep_min")
        XCTAssertEqual(batch.metrics.last?.metric, "height_in")
    }

    func testWeighInsAndBody() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        XCTAssertEqual(batch.weights.map(\.measuredAt), ["2026-11-10T14:00:00.000Z", "2026-11-24T14:00:00.000Z"])
        XCTAssertEqual(batch.weights.map(\.weightLb), [198.4, 257.2])
        XCTAssertEqual(batch.body.map(\.metric), ["body_fat_pct", "body_fat_pct", "lean_mass_lb"])
        XCTAssertEqual(batch.body.map(\.measuredAt), ["2026-11-10T18:00:00.000Z", "2026-11-24T14:01:00.000Z", "2026-11-24T14:01:00.000Z"])
        // Lean mass only from a weigh-in within 2 minutes: 257.2 x (1 - 0.368).
        XCTAssertEqual(batch.body.map(\.value), [25, 36.8, 162.6])
    }

    func testWorkouts() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        XCTAssertEqual(batch.workouts.count, 2)
        let run = batch.workouts[0]
        XCTAssertEqual(run.startedAt, "2026-11-23T13:00:00.000Z")
        XCTAssertEqual(run.endedAt, "2026-11-23T13:45:00.000Z")
        XCTAssertEqual(run.activity, "running")
        XCTAssertEqual(run.durationMin, 45)
        XCTAssertEqual(run.distanceMi, 5)
        XCTAssertEqual(run.activeKcal, 513)
        XCTAssertEqual(run.indoor, false)
        let hiit = batch.workouts[1]
        XCTAssertEqual(hiit.startedAt, "2026-11-25T00:00:00.000Z")
        XCTAssertEqual(hiit.endedAt, "2026-11-25T00:21:00.000Z")
        XCTAssertEqual(hiit.activity, "high intensity interval training")
        XCTAssertEqual(hiit.durationMin, 20.6)
        XCTAssertNil(hiit.distanceMi)
        XCTAssertNil(hiit.activeKcal)
        XCTAssertNil(hiit.indoor)
    }

    func testWorkoutNamesMatchThePlugin() {
        XCTAssertEqual(HealthKitReader.workoutName(.traditionalStrengthTraining), "strengthTraining")
        XCTAssertEqual(HealthKitReader.workoutName(.running), "running")
        XCTAssertEqual(HealthKitReader.workoutName(.stairClimbing), "other")
        XCTAssertEqual(HealthAggregate.words(HealthKitReader.workoutName(.highIntensityIntervalTraining)), "high intensity interval training")
        XCTAssertEqual(HealthAggregate.words(HealthKitReader.workoutName(.traditionalStrengthTraining)), "strength training")
        XCTAssertEqual(HealthAggregate.words(nil), "other")
        XCTAssertEqual(HealthAggregate.words(""), "other")
        XCTAssertEqual(HealthKitReader.metadataText(NSNumber(value: true)), "1")
        XCTAssertEqual(HealthKitReader.metadataText("true"), "true")
        XCTAssertNil(HealthKitReader.metadataText(nil))
    }

    func testSleepStageNames() {
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.inBed.rawValue), "inBed")
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue), "asleep")
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.awake.rawValue), "awake")
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.asleepCore.rawValue), "light")
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.asleepDeep.rawValue), "deep")
        XCTAssertEqual(HealthKitReader.sleepState(HKCategoryValueSleepAnalysis.asleepREM.rawValue), "rem")
    }

    func testSleepGapStartsANewNight() {
        // Two watch sessions more than 2 hours apart that end on different days.
        let w: HealthWindowSamples = {
            var w = HealthWindowSamples()
            w.sleep = [s(a, -2, 6, 480, "watch", state: "asleep"), s(b, 1, 5, 240, "watch", state: "asleep")]
            return w
        }()
        let batch = HealthAggregate.collect(w, startKey: a, endKey: b, includeDays: true)
        XCTAssertEqual(batch.days.map(\.sleepHours), [8, 4])
        XCTAssertTrue(batch.metrics.isEmpty) // no stages recorded, no in-bed
    }

    // MARK: Rounding and helpers

    func testRoundsLikeJavaScript() {
        XCTAssertEqual(HealthAggregate.jsRound(2.5), 3)
        XCTAssertEqual(HealthAggregate.jsRound(-2.5), -2)
        XCTAssertEqual(HealthAggregate.jsRound(-2.6), -3)
        XCTAssertEqual(HealthAggregate.jsRound(0.49999999999999994), 0)
        XCTAssertEqual(HealthAggregate.r1(15.25), 15.3)
        XCTAssertEqual(HealthAggregate.r2(7.8333), 7.83)
    }

    func testUnionMinutes() {
        let m = 60_000.0
        XCTAssertEqual(HealthAggregate.unionMinutes([(0, 30 * m), (10 * m, 40 * m), (60 * m, 70 * m), (5 * m, 5 * m)]), 50)
        XCTAssertEqual(HealthAggregate.unionMinutes([]), 0)
    }

    func testSplitAndMerge() {
        XCTAssertEqual(HealthAggregate.splitEnd(startKey: "2026-11-15", endKey: "2026-11-24"), "2026-11-19")
        XCTAssertNil(HealthAggregate.splitEnd(startKey: b, endKey: b))
        var older = HealthBatch()
        older.weights = [HealthWeightRow(measuredAt: "x", weightLb: 200, at: Date())]
        older.maxCount = 7
        var newer = HealthBatch()
        newer.weights = [HealthWeightRow(measuredAt: "x", weightLb: 201, at: Date()), HealthWeightRow(measuredAt: "y", weightLb: 202, at: Date())]
        newer.maxCount = 9
        newer.truncated = true
        let merged = HealthAggregate.merge(older: older, newer: newer)
        XCTAssertEqual(merged.weights.map(\.measuredAt), ["x", "y"])
        XCTAssertEqual(merged.weights.map(\.weightLb), [201, 202]) // first position, last value
        XCTAssertEqual(merged.maxCount, 9)
        XCTAssertFalse(merged.truncated)
    }

    // MARK: Payloads

    func testRequestsAndChunks() {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        let reqs = HealthPayload.requests(for: batch)
        XCTAssertEqual(reqs.map(\.action), ["health_sync", "health_sync", "health_sync", "health_sync", "health_metrics"])
        XCTAssertEqual(reqs.map { Array($0.payload.keys) }, [["days"], ["weights"], ["body"], ["workouts"], ["metrics"]])

        var big = HealthBatch()
        big.metrics = (0..<650).map { HealthMetricRow(day: a, metric: "m\($0)", value: 1, unit: "x") }
        big.days = (0..<40).map { HealthDayRow(day: LogTime.shift(a, -$0)) }
        let parts = HealthPayload.requests(for: big)
        XCTAssertEqual(parts.map(\.action), ["health_sync", "health_sync", "health_metrics", "health_metrics", "health_metrics"])
        XCTAssertEqual(parts.compactMap { ($0.payload["metrics"] as? [Any])?.count }, [300, 300, 50])
        XCTAssertEqual(parts.compactMap { ($0.payload["days"] as? [Any])?.count }, [31, 9])
    }

    func testJSONNumbersMatchTheWeb() throws {
        let batch = HealthAggregate.collect(window(), startKey: a, endKey: b, includeDays: true)
        let reqs = HealthPayload.requests(for: batch)
        func text(_ i: Int) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["action": reqs[i].action, "payload": reqs[i].payload], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        let days = try text(0)
        XCTAssertTrue(days.contains("\"sleep_hours\":7.83"), days)
        XCTAssertTrue(days.contains("\"vo2max\":39.1"), days)
        XCTAssertTrue(days.contains("\"distance_mi\":4,"), days)
        XCTAssertTrue(days.contains("\"steps\":9124"), days)
        XCTAssertFalse(days.contains("hrv_ms\":71."), days)
        let workouts = try text(3)
        XCTAssertTrue(workouts.contains("\"distance_mi\":null"), workouts)
        XCTAssertTrue(workouts.contains("\"indoor\":false"), workouts)
        XCTAssertTrue(workouts.contains("\"indoor\":null"), workouts)
        XCTAssertTrue(workouts.contains("\"duration_min\":20.6"), workouts)
        let metrics = try text(4)
        XCTAssertTrue(metrics.contains("\"value\":95.18"), metrics)
        XCTAssertTrue(metrics.contains("\"value\":0.1}"), metrics)
        XCTAssertFalse(metrics.contains("0000000"), metrics)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reqs[4].payload))
    }

    func testCountsFromResponses() {
        var r = HealthSyncResult()
        r.add(response: ["ok": true, "action": "health_sync", "days": 2, "weights": 1, "body": 0, "workouts": 1])
        r.add(response: ["ok": true, "action": "health_metrics", "metrics": 140])
        XCTAssertEqual([r.days, r.weights, r.body, r.workouts, r.metrics], [2, 1, 0, 1, 140])
        XCTAssertEqual(r.stored, 144)
        XCTAssertEqual(r.values, 142)
    }

    // MARK: Backfill

    func testBackfillWindows() {
        XCTAssertEqual(HealthBackfillState.windowStart(end: "2015-01-05", size: 10), "2015-01-01")
        XCTAssertEqual(HealthBackfillState.windowStart(end: b, size: 10), "2026-11-15")
        var st = HealthBackfillState()
        XCTAssertEqual(st.nextEnd(today: "2026-11-25"), b)
        // An empty window: counts its days, doubles the next window.
        st.record(startKey: "2026-11-15", endKey: b, batch: HealthBatch(), stored: 0)
        XCTAssertEqual(st.cursor, "2026-11-15")
        XCTAssertEqual(st.emptyDays, 10)
        XCTAssertEqual(st.windowSize, 20)
        XCTAssertNil(st.oldest)
        XCTAssertEqual(st.nextEnd(today: "2026-11-25"), "2026-11-14")
        // A busy window: resets the empty count, halves the window, tracks the oldest day.
        var busy = HealthBatch()
        busy.metrics = [HealthMetricRow(day: "2026-10-30", metric: "flights", value: 3, unit: "count"),
                        HealthMetricRow(day: "2026-10-27", metric: "flights", value: 4, unit: "count")]
        busy.maxCount = 6000
        st.record(startKey: "2026-10-26", endKey: "2026-11-14", batch: busy, stored: 2)
        XCTAssertEqual(st.emptyDays, 0)
        XCTAssertEqual(st.windowSize, 10)
        XCTAssertEqual(st.oldest, "2026-10-27")
        XCTAssertEqual(st.values, 2)
        // Never bigger than 60 or smaller than 5.
        st.size = 60
        st.record(startKey: "2026-08-27", endKey: "2026-10-25", batch: HealthBatch(), stored: 0)
        XCTAssertEqual(st.windowSize, 60)
        st.size = 5
        st.record(startKey: "2026-08-22", endKey: "2026-08-26", batch: busy, stored: 0)
        XCTAssertEqual(st.windowSize, 5)
        // Stops below the floor or after a year with nothing in it.
        XCTAssertTrue(HealthBackfillState.shouldContinue(end: "2015-01-01", empty: 364))
        XCTAssertFalse(HealthBackfillState.shouldContinue(end: "2014-12-31", empty: 0))
        XCTAssertFalse(HealthBackfillState.shouldContinue(end: "2020-01-01", empty: 365))
    }

    func testHistoryAlreadyThere() {
        let today = "2026-11-25"
        // health_span back to 2017 and metrics filling the payload's 120 days: the web backfill ran.
        XCTAssertTrue(HealthBackfillState.historyAlreadyThere(firstHealthDay: "2017-03-02", earliestMetricDay: "2026-07-28", today: today))
        // Only a catch-up's 30 days of metrics.
        XCTAssertFalse(HealthBackfillState.historyAlreadyThere(firstHealthDay: "2017-03-02", earliestMetricDay: "2026-10-27", today: today))
        // Less than a year of daily totals.
        XCTAssertFalse(HealthBackfillState.historyAlreadyThere(firstHealthDay: "2026-01-10", earliestMetricDay: "2026-07-28", today: today))
        XCTAssertFalse(HealthBackfillState.historyAlreadyThere(firstHealthDay: nil, earliestMetricDay: "2026-07-28", today: today))
        XCTAssertFalse(HealthBackfillState.historyAlreadyThere(firstHealthDay: "2017-03-02", earliestMetricDay: nil, today: today))
        let seeded = HealthBackfillState.alreadyDone(firstDay: "2017-03-02")
        XCTAssertTrue(seeded.done)
        XCTAssertEqual(HealthText.backfill(seeded), "History is already in the log, going back to Mar 2017.")
        XCTAssertEqual(HealthText.backfillButton(seeded), "Backfill again")
    }

    // MARK: Words (app.js renderHealthSync, health.js backfillText)

    func testSummary() {
        var r = HealthSyncResult()
        XCTAssertEqual(HealthText.summary(r), "Synced. Nothing new in Apple Health.")
        r.workouts = 1
        XCTAssertEqual(HealthText.summary(r), "Synced 1 workout.")
        r = HealthSyncResult()
        r.days = 2
        r.weights = 1
        r.metrics = 1400
        XCTAssertEqual(HealthText.summary(r), "Synced 2 days, 1 weigh-in and 1,400 other values.")
        r.body = 2
        XCTAssertEqual(HealthText.summary(r), "Synced 2 days, 1 weigh-in, 2 body readings and 1,400 other values.")
    }

    func testLastSynced() {
        let t = LogTime.parse("2026-11-24T15:30:00Z")!
        XCTAssertEqual(HealthText.lastSynced(t), "Last synced Nov 24, 9:30 AM")
    }

    func testBackfillText() {
        var st = HealthBackfillState()
        XCTAssertEqual(HealthText.backfill(st), "")
        XCTAssertEqual(HealthText.backfillButton(st), "Backfill history")
        st.running = true
        XCTAssertEqual(HealthText.backfill(st), "Backfilling history: starting…")
        XCTAssertEqual(HealthText.backfillButton(st), "Backfilling…")
        st.cursor = "2024-03-10"
        st.values = 1234
        XCTAssertEqual(HealthText.backfill(st), "Backfilling history: back to Mar 2024 so far, 1,234 values saved.")
        st.running = false
        XCTAssertEqual(HealthText.backfill(st), "History backfilled back to Mar 2024 so far. It carries on next time the app opens.")
        XCTAssertEqual(HealthText.backfillButton(st), "Continue backfill")
        st.error = "Couldn’t sync: Couldn’t reach the log. Check your connection."
        XCTAssertEqual(HealthText.backfill(st), "Backfill stopped at Mar 2024: Couldn’t reach the log. Check your connection. It tries again next time the app opens.")
        st.error = nil
        st.done = true
        st.oldest = "2017-03-02"
        XCTAssertEqual(HealthText.backfill(st), "History backfilled: 1,234 values saved, going back to Mar 2017.")
        XCTAssertEqual(HealthText.backfillButton(st), "Backfill again")
        st.oldest = nil
        XCTAssertEqual(HealthText.backfill(st), "History backfilled. Apple Health had nothing older to add.")
        st.values = 1
        st.oldest = "2017-03-02"
        XCTAssertEqual(HealthText.backfill(st), "History backfilled: 1 value saved, going back to Mar 2017.")
    }

    func testErrorWords() {
        XCTAssertEqual(HealthText.error(LogError.unauthorized), "Your sign-in ran out. Sign in again.")
        XCTAssertEqual(HealthText.error(LogError.server("invalid_entry")), "Couldn’t sync: invalid_entry")
        XCTAssertEqual(HealthText.error(HealthSyncError.unavailable), "Apple Health isn't available on this device.")
    }

    // MARK: Status

    @MainActor
    func testCatchUpThrottleAndFirstSync() {
        let suite = "LogHealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let status = HealthSyncStatus(defaults: defaults)
        XCTAssertEqual(status.statusLine, "Not synced yet")
        XCTAssertFalse(status.hasBackfillRecord)
        // The first catch-up on this phone takes 30 days.
        XCTAssertEqual(status.beginSync(.catchUp, days: 2), 30)
        XCTAssertNil(status.beginSync(.manual, days: 30)) // one at a time
        var r = HealthSyncResult()
        r.days = 2
        let now = Date()
        status.endSync(.catchUp, r, record: HealthSyncRecord(at: now, result: r))
        XCTAssertNil(status.message)
        XCTAssertEqual(status.statusLine, HealthText.lastSynced(now))
        // Another catch-up within a minute is skipped; one you ask for isn't.
        XCTAssertNil(status.beginSync(.catchUp, days: 2, now: now.addingTimeInterval(30)))
        XCTAssertEqual(status.beginSync(.manual, days: 7, now: now.addingTimeInterval(30)), 7)
        status.endSync(.manual, r, record: HealthSyncRecord(at: now, result: r))
        XCTAssertEqual(status.statusLine, "Synced 2 days.")
        XCTAssertEqual(status.manualSyncs, 1)
        XCTAssertEqual(status.beginSync(.catchUp, days: 2, now: now.addingTimeInterval(90)), 2)
        var failed = HealthSyncResult()
        failed.error = "Couldn’t sync: invalid_entry"
        status.endSync(.catchUp, failed, record: nil)
        XCTAssertTrue(status.isError)
        // The record survives a relaunch; messages don't.
        let again = HealthSyncStatus(defaults: defaults)
        XCTAssertEqual(again.last?.days, 2)
        XCTAssertNil(again.message)
    }

    @MainActor
    func testBackfillStateIsSaved() {
        let suite = "LogHealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let status = HealthSyncStatus(defaults: defaults)
        guard var b = status.beginBackfill(restart: false) else { return XCTFail("didn't start") }
        XCTAssertNil(status.beginBackfill(restart: false)) // already running
        let end = b.nextEnd(today: "2026-11-25")
        b.record(startKey: "2026-11-15", endKey: end, batch: HealthBatch(), stored: 0)
        status.setBackfill(b)
        let again = HealthSyncStatus(defaults: defaults)
        XCTAssertTrue(again.hasBackfillRecord)
        XCTAssertFalse(again.backfill.running) // a relaunch never shows it running
        XCTAssertEqual(again.backfill.cursor, "2026-11-15")
        var done = again.backfill
        done.done = true
        again.setBackfill(done)
        XCTAssertNil(again.beginBackfill(restart: false))
        let restarted = again.beginBackfill(restart: true)
        XCTAssertNil(restarted?.cursor)
        XCTAssertEqual(restarted?.running, true)
    }
}
