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

    func testReminderSettingsRoundTrip() {
        let name = "log.reminders.tests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let saved = ReminderSettings(shot: true, shotHour: 9, shotMinute: 30, checkin: true, weighIn: false, shotPromptDismissed: true)
        saved.save(defaults)
        XCTAssertEqual(ReminderSettings.load(defaults), saved)
        XCTAssertEqual(ReminderSettings(shotHour: 99).shotHour, 9)
        XCTAssertEqual(ReminderSettings(shotMinute: 80).shotMinute, 0)
        let six = ReminderSettings.clock(18, 0)
        XCTAssertTrue(six.hasPrefix("6:00") && six.contains("PM"), six)
        defaults.removePersistentDomain(forName: name)
    }

    func testReminderPlanKeepsMissedDose() throws {
        let open = try Self.planDashboard(doses: "[]")
        let evening = LogTime.parse("2026-11-24T23:20:00-06:00")!
        XCTAssertTrue(ReminderPlanner.requests(open, settings: ReminderSettings(), now: evening).isEmpty)

        let daily = ReminderSettings(checkin: true, weighIn: true)
        let habits = ReminderPlanner.requests(open, settings: daily, now: evening)
        XCTAssertEqual(habits.map(\.id), ["log.checkin", "log.weigh"])
        XCTAssertEqual(habits.map(\.hour), [18, 8])
        XCTAssertEqual(habits.map(\.route), ["checkin", "weigh"])
        XCTAssertTrue(habits.allSatisfy { $0.day == nil })

        let shot = ReminderSettings(shot: true, shotHour: 9)
        XCTAssertEqual(ReminderPlanner.requests(open, settings: shot, now: evening).map(\.id), [
            "log.shot.2026-11-29",
            "log.shot.2026-12-06",
            "log.shot.2026-11-29.due.2026-11-30",
            "log.shot.2026-11-29.due.2026-12-01",
            "log.shot.2026-11-29.due.2026-12-02",
            "log.shot.2026-11-29.due.2026-12-03",
            "log.shot.2026-11-29.due.2026-12-04",
            "log.shot.2026-11-29.due.2026-12-05",
        ])

        let afterShotTime = LogTime.parse("2026-11-30T10:00:00-06:00")!
        let late = ReminderPlanner.requests(open, settings: shot, now: afterShotTime)
        XCTAssertFalse(late.contains { $0.day == "2026-11-29" || $0.day == "2026-11-30" })
        let catchUp = try XCTUnwrap(late.first { $0.day == "2026-12-01" })
        XCTAssertEqual(catchUp.title, "Dose overdue")
        XCTAssertTrue(catchUp.body.contains("Sun, Nov 29"))
        XCTAssertEqual(catchUp.route, "meds")
        XCTAssertEqual(late.first { $0.day == "2026-12-06" }?.title, "Shot day")

        let beforeShotTime = LogTime.parse("2026-11-30T08:00:00-06:00")!
        XCTAssertTrue(ReminderPlanner.requests(open, settings: shot, now: beforeShotTime).contains { $0.day == "2026-11-30" && $0.title == "Dose overdue" })

        let weeksLater = LogTime.parse("2026-12-20T08:00:00-06:00")!
        let still = ReminderPlanner.requests(open, settings: shot, now: weeksLater)
        XCTAssertTrue(still.contains { $0.title == "Dose overdue" && $0.day == "2026-12-20" })
        XCTAssertFalse(still.contains { $0.id == "log.shot.2026-11-29" || $0.id == "log.shot.2026-12-06" })

        let logged = try Self.planDashboard(doses: #"[{"taken_at":"2026-11-30T18:00:00Z","compound":"tirzepatide","dose_mg":3,"skipped":false}]"#)
        let moved = ReminderPlanner.requests(logged, settings: shot, now: afterShotTime)
        XCTAssertFalse(moved.contains { $0.body.contains("Nov 29") })
        XCTAssertEqual(moved.first { $0.day == "2026-12-06" }?.body, "Retatrutide 2.0 mg today.")
    }

    private static func planDashboard(doses: String) throws -> Dashboard {
        let json = """
        {"doses":\(doses),"dose_plan":[{"planned_on":"2026-11-29","compound":"tirzepatide","dose_mg":3},{"planned_on":"2026-12-06","compound":"retatrutide","dose_mg":2,"units":20}]}
        """
        return try Dashboard.decode(Data(json.utf8))
    }
}
