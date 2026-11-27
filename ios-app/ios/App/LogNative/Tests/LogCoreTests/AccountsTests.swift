import XCTest
@testable import LogCore

final class AccountsTests: XCTestCase {
    func testMealReplyParsesThroughCodeFences() {
        let reply = """
        Here you go:
        ```json
        {"meal_type": "Lunch", "items": [{"item": "Chicken bowl", "quantity": "1 bowl", "calories": 620, "protein_g": "45", "carbs_g": 60, "fat_g": 18}, {"item": "", "calories": 10}]}
        ```
        """
        let e = MealAI.parse(reply)
        XCTAssertEqual(e.mealType, "lunch")
        XCTAssertEqual(e.items.count, 1)
        XCTAssertEqual(e.items.first?.item, "Chicken bowl")
        XCTAssertEqual(e.items.first?.proteinG, 45)
        XCTAssertEqual(e.items.first?.calories, 620)
    }

    func testMealReplyThatIsNotFoodIsEmpty() {
        XCTAssertTrue(MealAI.parse("{\"items\": []}").items.isEmpty)
        XCTAssertTrue(MealAI.parse("I can't help with that.").items.isEmpty)
    }

    func testMealPayloadRoundsAndTags() {
        let p = MealAI.payload([MealItem(item: "Toast", calories: 120.04, proteinG: 4.26)], mealType: "breakfast", eatenAt: Date(timeIntervalSince1970: 0), usedAI: true)
        XCTAssertEqual(p["source"] as? String, "app-ai")
        XCTAssertEqual(p["meal_type"] as? String, "breakfast")
        let item = (p["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["calories"] as? Double, 120)
        XCTAssertEqual(item?["protein_g"] as? Double, 4.3)
    }

    func testCentralNoonIsUnchanged() {
        // 18:00 UTC, as the web app's keyToNoon.
        XCTAssertEqual(LogTime.noon("2026-11-24").timeIntervalSince1970, 1795543200)
        XCTAssertEqual(LogTime.dayKey(LogTime.noon("2026-11-24")), "2026-11-24")
        XCTAssertEqual(LogTime.dayDiff("2026-12-01", "2026-11-24"), 7)
        XCTAssertEqual(LogTime.monday("2026-11-26"), "2026-11-23")
    }

    func testAnotherZoneKeepsDayKeys() {
        let original = LogTime.zone
        defer { LogTime.use(zone: original) }
        for id in ["Pacific/Auckland", "Pacific/Kiritimati", "Asia/Kolkata", "Europe/London", "Pacific/Honolulu"] {
            LogTime.use(zone: TimeZone(identifier: id)!)
            XCTAssertEqual(LogTime.dayKey(LogTime.noon("2026-11-24")), "2026-11-24", id)
            XCTAssertEqual(LogTime.dayKey(LogTime.startOfDay("2026-11-24")), "2026-11-24", id)
            XCTAssertEqual(LogTime.shift("2026-11-24", 7), "2026-12-01", id)
            XCTAssertEqual(LogTime.monday("2026-11-26"), "2026-11-23", id)
        }
    }

    func testSessionExpiry() {
        let s = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: 1_000, userId: "u", email: nil)
        XCTAssertTrue(s.expiresSoon(now: Date(timeIntervalSince1970: 900)))
        XCTAssertFalse(s.expiresSoon(now: Date(timeIntervalSince1970: 100)))
    }
}
