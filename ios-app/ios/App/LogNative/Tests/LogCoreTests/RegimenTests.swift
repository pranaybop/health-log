import XCTest
import LogCore

/// Daily peptide schedules (made-up data).
final class RegimenTests: XCTestCase {
    private func dashboard(doses: String) throws -> Dashboard {
        let json = """
        {"regimens":[{"compound":"tesamorelin","display_name":"Tesamorelin","dose_mg":1.4,"every_days":1,
          "start_on":"2026-12-20","end_on":"2027-02-28","concentration_mg_per_ml":10,"status":"planned"}],
         "doses":\(doses)}
        """
        return try Dashboard.decode(Data(json.utf8))
    }

    func testPeptideDosesStayOutOfGLP1Doses() throws {
        let d = try dashboard(doses: #"[{"taken_at":"2026-12-20T03:00:00Z","compound":"tesamorelin","dose_mg":1.4},{"taken_at":"2026-12-06T18:00:00Z","compound":"retatrutide","dose_mg":2.5}]"#)
        XCTAssertEqual(d.doses.map(\.compound), ["retatrutide"])
        XCTAssertEqual(d.peptideDoses.map(\.compound), ["tesamorelin"])
    }

    func testScheduleBeforeAndDuring() throws {
        let d = try dashboard(doses: "[]")
        let r = d.regimens[0]
        XCTAssertEqual(r.frequencyText, "daily")
        XCTAssertEqual(r.drawUnits ?? 0, 14, accuracy: 0.001)
        XCTAssertFalse(r.isDoseDay("2026-12-19"))
        XCTAssertTrue(r.isDoseDay("2026-12-20"))
        XCTAssertTrue(r.isDoseDay("2027-02-28"))
        XCTAssertFalse(r.isDoseDay("2027-03-01"))

        let before = Analytics.regimenStatuses(d, now: LogTime.parse("2026-11-25T12:00:00-06:00")!)[0]
        XCTAssertEqual(before.daysToStart, 25)
        XCTAssertEqual(before.nextDay, "2026-12-20")
        XCTAssertEqual(before.totalShots, 71)
        XCTAssertFalse(before.dueToday)

        let first = Analytics.regimenStatuses(d, now: LogTime.parse("2026-12-20T20:00:00-06:00")!)[0]
        XCTAssertTrue(first.dueToday)
        XCTAssertFalse(first.loggedToday)
        XCTAssertEqual(first.nextDay, "2026-12-20")
        XCTAssertEqual(first.shotNumber, 1)
    }

    func testLoggedTonightMovesToTomorrow() throws {
        let d = try dashboard(doses: #"[{"taken_at":"2026-12-21T03:30:00Z","compound":"tesamorelin","dose_mg":1.4,"site":"Abd UR"}]"#)
        let s = Analytics.regimenStatuses(d, now: LogTime.parse("2026-12-20T22:00:00-06:00")!)[0]
        XCTAssertTrue(s.loggedToday)
        XCTAssertEqual(s.nextDay, "2026-12-21")
        XCTAssertEqual(Analytics.nextBellySite(d, compound: "tesamorelin"), "Abd LR")
    }

    func testCycleDaysOnOff() throws {
        let json = #"{"regimens":[{"compound":"tesamorelin","dose_mg":1,"days_on":5,"days_off":2,"start_on":"2026-12-21"}]}"#
        let r = try Dashboard.decode(Data(json.utf8)).regimens[0]
        XCTAssertEqual(r.frequencyText, "5 days on, 2 off")
        XCTAssertTrue(r.isDoseDay("2026-12-25"))
        XCTAssertFalse(r.isDoseDay("2026-12-26"))
        XCTAssertFalse(r.isDoseDay("2026-12-27"))
        XCTAssertTrue(r.isDoseDay("2026-12-28"))
    }
}
