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
        XCTAssertEqual(s.changes.last?.label, "All time")
        XCTAssertEqual(s.dayShift ?? 0, -0.25, accuracy: 1e-9)
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
